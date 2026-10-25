import Foundation
import Darwin
import PhotoBridgeCore

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ExportError.invalidManifest(message) }
}
func rejects(_ message: String, _ operation: () throws -> Void) throws {
    var failed = false; do { try operation() } catch { failed = true }; try require(failed, message)
}
func peakRSS() -> Int64 { var info = rusage(); getrusage(RUSAGE_SELF, &info); return Int64(info.ru_maxrss) }
let count = Int(ProcessInfo.processInfo.environment["PHOTOBRIDGE_SCALE_COUNT"] ?? "50000") ?? 50000
try require(count >= 20 && count <= 50000, "Scale count must be 20...50000")
let begin = Date(); let memoryBefore = peakRSS()
let sources = (1...count).map { String(format: "source-%06d", $0) }
let created = (1...count).map { String(format: "new-%06d", $0) }
let mapping = Dictionary(uniqueKeysWithValues: zip(sources, created))
try RestoreSafety.verifyOrder(sourceIDs: sources, mapping: mapping, observed: created)
for position in [0, count / 2, count - 1] {
    var wrong = created; wrong.swapAt(position, (position + 1) % count)
    try rejects("reordered member at \(position) must fail") { try RestoreSafety.verifyOrder(sourceIDs: sources, mapping: mapping, observed: wrong) }
}
try rejects("missing last member must fail") { try RestoreSafety.verifyOrder(sourceIDs: sources, mapping: mapping, observed: Array(created.dropLast())) }
var duplicate = created; duplicate[count - 1] = created[0]
try rejects("duplicate member must fail") { try RestoreSafety.verifyOrder(sourceIDs: sources, mapping: mapping, observed: duplicate) }
let dateSource = OrderSnapshot(albumName: "synthetic date", albumIdentifier: "date-album", authorization: "full", fetchMode: "nil-options",
    identifiers: ["date-source"], creationDates: [Date(timeIntervalSince1970: 1)], systemVersion: "synthetic", build: "test")
let dateResource = ExportResource(resourceIndex: 1, resourceType: 1, originalFilename: "date.JPG", uniformTypeIdentifier: "public.jpeg",
    storedRelativePath: "Resources/000001/0001.JPG", sha256: String(repeating: "a", count: 64), byteCount: 1)
let inconsistent = ExportAsset(ordinal: 1, resourceGroupId: UUID().uuidString, sourceAssetLocalIdentifier: "date-source",
    originalPhotoLibraryCreationDate: Date(timeIntervalSince1970: 2), pixelWidth: 10, pixelHeight: 10, mediaType: 1, mediaSubtypes: 0, resources: [dateResource])
try rejects("Contradictory source creation dates must fail") {
    try AlbumExportManifest(sessionID: UUID().uuidString, sourceOrder: dateSource, assets: [inconsistent]).validate()
}
try RestoreSafety.verifyCreationDate(expected: Date(timeIntervalSince1970: 1), observed: Date(timeIntervalSince1970: 1))
try RestoreSafety.verifyCreationDate(expected: nil, observed: nil)
try rejects("Changed Photos creation date must fail") { try RestoreSafety.verifyCreationDate(expected: Date(timeIntervalSince1970: 1), observed: Date(timeIntervalSince1970: 2)) }
try rejects("Missing Photos creation date must fail") { try RestoreSafety.verifyCreationDate(expected: Date(timeIntervalSince1970: 1), observed: nil) }
let orderSeconds = Date().timeIntervalSince(begin)

// Compare every boundary with the original, independently calculated budget.
let sample: [[Int64]] = [[10,20], [40], [50,60], [70]]
let samplePlan = try RestoreBudgetPlan(resourceBytesByAsset: sample)
for recorded in 0...sample.count {
    for verified in 0...recorded {
        let expected = try RestoreWriteBudget(resourceBytesByAsset: sample, recordedAssets: recorded, verifiedThisRun: verified)
        try require(samplePlan.budget(recordedAssets: recorded, verifiedThisRun: verified) == expected, "Indexed budget differs from full calculation")
        if verified < recorded {
            let partial = sample[verified][0]
            let expectedPartial = try RestoreWriteBudget(resourceBytesByAsset: sample, recordedAssets: recorded, verifiedThisRun: verified, committedResourceBytesInCurrentAsset: partial)
            try require(samplePlan.budget(recordedAssets: recorded, verifiedThisRun: verified, committedResourceBytesInCurrentAsset: partial) == expectedPartial, "Partial budget differs")
        }
    }
}
try rejects("overflow fails closed") { _ = try RestoreBudgetPlan(resourceBytesByAsset: [[Int64.max], [1]]) }
try rejects("invalid size fails closed") { _ = try RestoreBudgetPlan(resourceBytesByAsset: [[0]]) }
try rejects("invalid count fails closed") { _ = try samplePlan.budget(recordedAssets: Int.min, verifiedThisRun: 0) }
try rejects("oversized partial fails closed") { _ = try samplePlan.budget(recordedAssets: 1, verifiedThisRun: 0, committedResourceBytesInCurrentAsset: 31) }
let budgetStart = Date()
let sizes = (0..<count).map { $0.isMultiple(of: 3) ? [Int64(4_000_000), Int64(8_000_000)] : [Int64(4_000_000)] }
let plan = try RestoreBudgetPlan(resourceBytesByAsset: sizes)
var checksum: Int64 = 0
for i in 0..<count {
    let budget = try plan.budget(recordedAssets: i + 1, verifiedThisRun: i, committedResourceBytesInCurrentAsset: 1)
    checksum ^= budget.requiredBytes
}
let budgetSeconds = Date().timeIntervalSince(budgetStart)
try require(budgetSeconds < 5, "Capacity calculation must scale linearly at 50000 assets")
let benchmarkCount = min(count, 200)
let oldBegin = Date(); var oldChecksum: Int64 = 0
for i in 0..<benchmarkCount { oldChecksum ^= try RestoreWriteBudget(resourceBytesByAsset: sizes, recordedAssets: i + 1, verifiedThisRun: i).requiredBytes }
let oldSeconds = Date().timeIntervalSince(oldBegin)
let indexedBegin = Date(); var indexedChecksum: Int64 = 0
for i in 0..<benchmarkCount { indexedChecksum ^= try plan.budget(recordedAssets: i + 1, verifiedThisRun: i).requiredBytes }
let indexedSeconds = Date().timeIntervalSince(indexedBegin)
try require(oldChecksum == indexedChecksum, "Benchmark calculations must agree exactly")
let growth = peakRSS() - memoryBefore
try require(growth < 128 * 1024 * 1024, "Metadata-only checks exceed bounded memory")
var record: [String: Any] = ["synthetic": true, "assets": count, "orderChecks": "PASS exact order; first/middle/last swaps, missing and duplicate rejected",
    "orderSeconds": orderSeconds, "comparisonQueries": benchmarkCount, "originalCapacitySeconds": oldSeconds, "indexedCapacitySeconds": indexedSeconds, "capacityQueries": count, "capacitySeconds": budgetSeconds, "checksum": checksum,
    "peakRSSGrowthBytes": growth, "devicePhotosRoundTrip": "NOT_RUN", "usbThroughput": "NOT_MEASURED"]
print(String(data: try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)

try runSparseRecoveryScale()
if let count = Int(ProcessInfo.processInfo.environment["PHOTOBRIDGE_LEDGER_COUNT"] ?? "1000"), count >= 2, count <= 50000 {
    let ledger = try runRecoveryScale(count)
    print(String(data: try JSONSerialization.data(withJSONObject: ledger, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
}
