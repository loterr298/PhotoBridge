import Foundation

/// Logical photos, not resources: a Live Photo occupies one album position.
public struct PhotoProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int
    public let finished: Bool
    public init(completed: Int, total: Int, finished: Bool = false) {
        self.total = max(0, total)
        self.completed = min(max(0, completed), self.total)
        self.finished = finished && total > 0 && completed == total
    }
    public var percent: Int? {
        guard total > 0 else { return nil }
        if finished { return 100 }
        let scaled = UInt(completed).multipliedFullWidth(by: 100)
        return min(99, Int(UInt(total).dividingFullWidth(scaled).quotient))
    }
    public var fraction: Double { Double(percent ?? 0) / 100 }
    public var countText: String { "\(completed.formatted()) / \(total.formatted()) 张" }
    public var percentText: String { percent.map { "\($0)%" } ?? "—" }
}

/// UI-only progress state. A transfer may publish the same journal more than
/// once or briefly expose an older poll result; the visible number must never
/// move backwards inside one phase. A new operation or phase starts a fresh
/// counter so scanning can hand off to copying without showing a false value.
public struct ProgressDisplayState: Equatable, Sendable {
    public private(set) var progress = PhotoProgress(completed: 0, total: 0)
    private var operationID = ""
    private var phase = ""

    public init() {}

    @discardableResult
    public mutating func update(_ candidate: PhotoProgress, operationID: String, phase: String = "") -> Bool {
        if self.operationID != operationID || self.phase != phase {
            self.operationID = operationID
            self.phase = phase
            progress = candidate
            return true
        }
        guard candidate.completed >= progress.completed else { return false }
        progress = candidate
        return true
    }
}

public enum ProgressNumber {
    /// Double(Int64.max) rounds UP to 2^63, which traps on direct conversion.
    public static func nonnegativeInt64(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}

/// Bounded mailbox: scanning 50000 photos never queues 50000 UI tasks.
public final class LatestPhotoCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PhotoProgress(completed: 0, total: 0)
    public init() {}
    public func update(completed: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        value = PhotoProgress(completed: completed, total: total)
    }
    public func read() -> PhotoProgress {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Advisory display only. Never authorizes Photos writes or media acceptance.
public struct TransferDisplay: Codable, Equatable, Sendable {
    public var kind = "PhotoBridgeTransferDisplay"
    public let operationID: String
    public let direction: String
    public let phase: String
    public let completed: Int
    public let total: Int
    public let sessionID: String
    public let updatedAt: Double
    public let elapsedSeconds: Double?
    public init(operationID: String, direction: String, phase: String, completed: Int, total: Int, sessionID: String, updatedAt: Double = Date().timeIntervalSince1970, elapsedSeconds: Double? = nil) {
        self.operationID = operationID; self.direction = direction; self.phase = phase
        self.completed = completed; self.total = total; self.sessionID = sessionID; self.updatedAt = updatedAt; self.elapsedSeconds = elapsedSeconds
    }
    public var finished: Bool {
        ["COMMITTED", "USB_VERIFIED", "PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED", "PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS"].contains(phase)
    }
    public var progress: PhotoProgress { PhotoProgress(completed: completed, total: total, finished: finished) }
    public var label: String {
        switch phase {
        case "COMMITTED": return "已保存到 Mac"
        case "USB_VERIFIED": return "已发送到 iPhone，等待导入"
        case "VERIFYING": return "正在核对发送结果"
        case "VERIFYING_IMPORTED_RESOURCES": return "正在核对导入结果"
        case "FINALIZING": return "正在完成最后检查"
        case "SCANNING", "WAITING_FOR_IPHONE", "CHECKING": return "正在读取照片"
        case "WAITING_FOR_PHOTO": return "正在准备下一张照片"
        case "STOPPED", "INCOMPLETE", "INTERRUPTED": return "已暂停，进度已保留"
        case "FAILED": return "传输没有完成，进度已保留"
        default:
            if phase.hasPrefix("PHOTO_LIBRARY_") { return "已导入到新相册" }
            return direction == "TO_MAC" ? "正在保存到 Mac" : direction == "IMPORT" ? "正在导入到相册" : "正在发送到 iPhone"
        }
    }
    public func presentationLabel(now: Double = Date().timeIntervalSince1970) -> String {
        if now - updatedAt > 15 || updatedAt > now + 60 {
            return finished ? "上次传输 · " + label : "进度已保留，等待 Mac 更新"
        }
        return label
    }
    public static func decode(_ data: Data) -> TransferDisplay? {
        guard data.count <= 65_536, let value = try? JSONDecoder().decode(Self.self, from: data),
              value.kind == "PhotoBridgeTransferDisplay", UUID(uuidString: value.operationID) != nil,
              ["TO_MAC", "TO_IPHONE", "IMPORT"].contains(value.direction),
              value.completed >= 0, value.total >= value.completed, value.updatedAt.isFinite,
              value.phase.count <= 128, value.sessionID.count <= 128,
              value.elapsedSeconds == nil || (value.elapsedSeconds?.isFinite == true && value.elapsedSeconds! >= 0) else { return nil }
        return value
    }
    public static func read(at url: URL) -> TransferDisplay? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              a[.type] as? FileAttributeType == .typeRegular,
              let size = a[.size] as? NSNumber, size.intValue <= 65_536,
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}

/// Live state for the direct Mac-to-Photos pipeline. This is separate from
/// persisted restore journals so an old interrupted job cannot overwrite the
/// current import counter on the iPhone.
public struct DirectImportProgress: Equatable, Sendable {
    public let sessionID: String
    public let completed: Int
    public let total: Int
    public let phase: String
    public let elapsedSeconds: Double

    public init(sessionID: String, completed: Int, total: Int, phase: String,
                elapsedSeconds: Double = 0) {
        self.sessionID = sessionID
        self.total = max(0, total)
        self.completed = min(max(0, completed), self.total)
        self.phase = phase
        self.elapsedSeconds = max(0, elapsedSeconds.isFinite ? elapsedSeconds : 0)
    }

    public var isActive: Bool { phase == "IMPORTING" || phase == "VERIFYING" }
    public var progress: PhotoProgress {
        PhotoProgress(completed: completed, total: total, finished: phase == "COMMITTED")
    }
}

/// PhotoKit transaction sizing for the direct importer. Each range is
/// contiguous and ordered, so batching can reduce database commits without
/// changing the album order.
public enum DirectImportBatching {
    public static let maxBatchSize = 128

    public static func ranges(total: Int, batchSize: Int = maxBatchSize) -> [Range<Int>] {
        guard total > 0 else { return [] }
        let size = max(1, batchSize)
        return stride(from: 0, to: total, by: size).map { start in
            start..<min(total, start + size)
        }
    }
}

public enum DirectOrderVerification {
    public static func matches(expected: [String], actual: [String]) -> Bool {
        guard !expected.isEmpty, Set(expected).count == expected.count else { return false }
        var expectedIndex = 0
        for identifier in actual where expectedIndex < expected.count {
            if identifier == expected[expectedIndex] { expectedIndex += 1 }
        }
        return expectedIndex == expected.count
    }
}

public enum DirectCachePolicy {
    public static func isOwnedSession(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && !value.contains("/") && !value.contains("\\")
    }

    public static func isOwnedRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "DirectInbox",
              isOwnedSession(String(parts[1])), parts[2].allSatisfy(\.isNumber) else { return false }
        return !value.hasPrefix("/") && !value.contains("..") && !value.contains("\\")
    }
}
