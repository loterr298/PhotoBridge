import Foundation

public enum PhotoAccessState: String, Codable {
    case full, limited, denied, restricted, notDetermined, unknown
}

public enum OperationPreconditionFailure: Error, LocalizedError {
    case photoAccess(PhotoAccessState)
    case capacityUnknown
    case insufficientSpace(required: Int64, available: Int64)
    case invalidBudget
    public var code: String {
        switch self {
        case .photoAccess: return "FULL_PHOTO_ACCESS_REQUIRED"
        case .capacityUnknown: return "AVAILABLE_CAPACITY_UNKNOWN"
        case .insufficientSpace: return "INSUFFICIENT_ESTIMATED_CAPACITY"
        case .invalidBudget: return "INVALID_WRITE_BUDGET"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .photoAccess(let state): return "需要全部照片权限（当前：\(state.rawValue)）。请在系统设置允许全部照片后重新预检；不自动重放事务"
        case .capacityUnknown: return "无法确认可用空间，已停止。请检查储存空间后重新预检，已有文件和副本保留"
        case .insufficientSpace(let required, let available):
            return "空间不足：估算需另留 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，当前可用 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。请自行整理其他存储后重新预检；本 App 不删除文件"
        case .invalidBudget: return "资源大小或进度超出安全估算范围，已停止"
        }
    }
}

public struct RestoreWriteBudget: Encodable, Equatable {
    public let remainingPhotoCopyBytes: Int64
    public let remainingReadbackBytes: Int64
    public let reserveBytes: Int64
    public let requiredBytes: Int64
    fileprivate init(photo: Int64, readback: Int64, reserve: Int64) throws {
        let (subtotal, overflow) = photo.addingReportingOverflow(readback)
        let (total, reserveOverflow) = subtotal.addingReportingOverflow(reserve)
        guard !overflow, !reserveOverflow else { throw OperationPreconditionFailure.invalidBudget }
        remainingPhotoCopyBytes = photo; remainingReadbackBytes = readback
        reserveBytes = reserve; requiredBytes = total
    }
    /// An estimate, not a reservation: Photos/system overhead and other processes can consume more space.
    public init(resourceBytesByAsset: [[Int64]], recordedAssets: Int, verifiedThisRun: Int,
                committedResourceBytesInCurrentAsset: Int64 = 0, reserveBytes: Int64 = 128 * 1024 * 1024) throws {
        guard !resourceBytesByAsset.isEmpty, recordedAssets >= 0, recordedAssets <= resourceBytesByAsset.count,
              verifiedThisRun >= 0, verifiedThisRun <= recordedAssets, committedResourceBytesInCurrentAsset >= 0, reserveBytes > 0 else { throw OperationPreconditionFailure.invalidBudget }
        func add(_ a: Int64, _ b: Int64) throws -> Int64 {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw OperationPreconditionFailure.invalidBudget }; return sum
        }
        var photo: Int64 = 0; var readback: Int64 = 0; var currentAssetBytes: Int64 = 0
        for (index, resources) in resourceBytesByAsset.enumerated() {
            guard !resources.isEmpty, resources.allSatisfy({ $0 > 0 }) else { throw OperationPreconditionFailure.invalidBudget }
            for size in resources {
                if index == verifiedThisRun { currentAssetBytes = try add(currentAssetBytes, size) }
                if index >= recordedAssets { photo = try add(photo, size) }
                if index >= verifiedThisRun { readback = try add(readback, size) }
            }
        }
        guard committedResourceBytesInCurrentAsset <= currentAssetBytes,
              committedResourceBytesInCurrentAsset == 0 || verifiedThisRun < recordedAssets else { throw OperationPreconditionFailure.invalidBudget }
        readback -= committedResourceBytesInCurrentAsset
        remainingPhotoCopyBytes = photo; remainingReadbackBytes = readback; self.reserveBytes = reserveBytes
        requiredBytes = try add(add(photo, readback), reserveBytes)
    }
}

/// Immutable size index: build once, then O(1) capacity estimates at every resource boundary.
/// This changes arithmetic cost only; actual available capacity is still queried before writes.
public struct RestoreBudgetPlan {
    private let prefix: [Int64]
    public init(resourceBytesByAsset: [[Int64]]) throws {
        guard !resourceBytesByAsset.isEmpty else { throw OperationPreconditionFailure.invalidBudget }
        var sums: [Int64] = [0]; sums.reserveCapacity(resourceBytesByAsset.count + 1)
        var total: Int64 = 0
        for resources in resourceBytesByAsset {
            guard !resources.isEmpty else { throw OperationPreconditionFailure.invalidBudget }
            for size in resources {
                let (next, overflow) = total.addingReportingOverflow(size)
                guard size > 0, !overflow else { throw OperationPreconditionFailure.invalidBudget }
                total = next
            }
            sums.append(total)
        }
        prefix = sums
    }
    public func budget(recordedAssets: Int, verifiedThisRun: Int, committedResourceBytesInCurrentAsset: Int64 = 0,
                       reserveBytes: Int64 = 128 * 1024 * 1024) throws -> RestoreWriteBudget {
        let count = prefix.count - 1
        guard recordedAssets >= 0, recordedAssets <= count, verifiedThisRun >= 0, verifiedThisRun <= recordedAssets,
              committedResourceBytesInCurrentAsset >= 0, reserveBytes > 0 else { throw OperationPreconditionFailure.invalidBudget }
        let current = verifiedThisRun < count ? prefix[verifiedThisRun + 1] - prefix[verifiedThisRun] : 0
        guard committedResourceBytesInCurrentAsset <= current,
              committedResourceBytesInCurrentAsset == 0 || verifiedThisRun < recordedAssets else { throw OperationPreconditionFailure.invalidBudget }
        return try RestoreWriteBudget(photo: prefix[count] - prefix[recordedAssets],
            readback: prefix[count] - prefix[verifiedThisRun] - committedResourceBytesInCurrentAsset, reserve: reserveBytes)
    }
}

public enum OperationPreconditions {
    public static func requireFullAccess(_ state: PhotoAccessState) throws {
        guard state == .full else { throw OperationPreconditionFailure.photoAccess(state) }
    }
    public static func requireCapacity(_ bytes: Int64?, budget: RestoreWriteBudget) throws {
        guard let bytes, bytes >= 0 else { throw OperationPreconditionFailure.capacityUnknown }
        guard bytes >= budget.requiredBytes else { throw OperationPreconditionFailure.insufficientSpace(required: budget.requiredBytes, available: bytes) }
    }
}
