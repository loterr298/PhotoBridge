import Foundation
import PhotoBridgeCore

func preconditionChecks() throws {
    try OperationPreconditions.requireFullAccess(.full)
    try check(true, "full library permission accepted")
    for permission in [PhotoAccessState.notDetermined, .restricted, .denied, .limited, .unknown] {
        try rejects("non-full permission refused: \(permission.rawValue)") { try OperationPreconditions.requireFullAccess(permission) }
    }
    let budget = try RestoreWriteBudget(resourceBytesByAsset: [[10, 20], [40], [50]], recordedAssets: 1, verifiedThisRun: 0, reserveBytes: 100)
    try check(budget.remainingPhotoCopyBytes == 90 && budget.remainingReadbackBytes == 120 && budget.requiredBytes == 310,
        "recovery budget rereads every existing asset but only copies remaining Photos assets")
    let next = try RestoreWriteBudget(resourceBytesByAsset: [[10,20], [40], [50]], recordedAssets: 2, verifiedThisRun: 1, reserveBytes: 100)
    try check(next.requiredBytes == 240, "budget decreases only for completed copy and readback work")
    try OperationPreconditions.requireCapacity(310, budget: budget)
    try check(true, "exact minimum estimated capacity accepted")
    try rejects("insufficient space refused before creation") { try OperationPreconditions.requireCapacity(309, budget: budget) }
    try rejects("unknown space fails closed") { try OperationPreconditions.requireCapacity(nil, budget: budget) }
    try rejects("negative capacity refused") { try OperationPreconditions.requireCapacity(-1, budget: budget) }
    try rejects("space arithmetic overflow refused") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[Int64.max]], recordedAssets: 0, verifiedThisRun: 0, reserveBytes: 1) }
    try rejects("negative resource size refused") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[-1]], recordedAssets: 0, verifiedThisRun: 0) }
    try rejects("invalid completed asset count refused") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[1]], recordedAssets: Int.min, verifiedThisRun: 0) }
    try rejects("readback count cannot exceed created assets") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[1]], recordedAssets: 0, verifiedThisRun: 1) }
    let partial = try RestoreWriteBudget(resourceBytesByAsset: [[1024, 1024]], recordedAssets: 1, verifiedThisRun: 0,
        committedResourceBytesInCurrentAsset: 1024, reserveBytes: 100)
    try check(partial.requiredBytes == 1124, "next resource budget subtracts already committed current-asset bytes")
    try OperationPreconditions.requireCapacity(1124, budget: partial)
    try check(true, "exact advertised remaining space permits final paired resource")
    try rejects("excess current-asset readback bytes refused") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[10]], recordedAssets: 1, verifiedThisRun: 0, committedResourceBytesInCurrentAsset: 11) }
    try rejects("negative readback bytes refused") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[10]], recordedAssets: 1, verifiedThisRun: 0, committedResourceBytesInCurrentAsset: -1) }
    let future = try RestoreWriteBudget(resourceBytesByAsset: [[1024, 1024], [512]], recordedAssets: 1, verifiedThisRun: 0,
        committedResourceBytesInCurrentAsset: 1024, reserveBytes: 100)
    try check(future.requiredBytes == 2148, "resource boundary retains future Photos copies and readbacks")
    try rejects("external capacity drop between resource writes stops before next resource") { try OperationPreconditions.requireCapacity(2147, budget: future) }
    try rejects("partial readback requires an existing unverified asset") { _ = try RestoreWriteBudget(resourceBytesByAsset: [[10]], recordedAssets: 0, verifiedThisRun: 0, committedResourceBytesInCurrentAsset: 1) }
    let all = try RestoreWriteBudget(resourceBytesByAsset: [[10]], recordedAssets: 1, verifiedThisRun: 1, reserveBytes: 100)
    try check(all.requiredBytes == 100, "completed work still keeps metadata reserve")
}
