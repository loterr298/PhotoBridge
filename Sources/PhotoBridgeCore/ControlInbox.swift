import Foundation

/// Immutable commands/responses; callers cache acknowledged IDs, not media data.
/// File enumeration/reads belong on a background worker, never the UI actor.
public enum ControlInbox {
    public struct Request: Sendable { public let id: String; public let data: Data }
    public struct Scan: Sendable { public let requests: [Request]; public let responded: Set<String> }
    public static func pending(in root: URL, ignoring: Set<String>, limit: Int = 8) throws -> Scan {
        try StagingResume.requireDirectory(root)
        let requests = root.appendingPathComponent("Requests")
        let responses = root.appendingPathComponent("Responses")
        try StagingResume.requireDirectory(requests); try StagingResume.requireDirectory(responses)
        var pending: [Request] = []; var responded: Set<String> = []; var rejected = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: requests.path).sorted() where name.hasSuffix(".json") {
            try Task.checkCancellation()
            let id = String(name.dropLast(5))
            guard UUID(uuidString: id) != nil, !ignoring.contains(id) else { continue }
            if FileManager.default.fileExists(atPath: responses.appendingPathComponent(name).path) { responded.insert(id); continue }
            let url = requests.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else { continue }
            let file = try FileHandle(forReadingFrom: url)
            let data: Data
            do { data = try file.read(upToCount: 65_537) ?? Data(); try file.close() }
            catch { try? file.close(); throw error }
            guard data.count <= 65_536 else { continue }
            guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any], request["id"] as? String == id else {
                let failure = try JSONSerialization.data(withJSONObject: ["status": "FAILED", "error": "连接请求无法读取，请在 Mac 重新操作。"], options: [.sortedKeys])
                try RestoreRecoveryStore.writeNewMetadata(failure, to: responses.appendingPathComponent(name))
                responded.insert(id); rejected += 1
                if rejected >= max(1, limit) { break }
                continue
            }
            pending.append(Request(id: id, data: data))
            if pending.count >= max(1, limit) { break }
        }
        return Scan(requests: pending, responded: responded)
    }
}

public struct WorkActivity: Sendable {
    private var active: Set<String> = []
    public var foreground = true
    public init() {}
    public mutating func set(_ key: String, active: Bool) {
        if active { self.active.insert(key) } else { self.active.remove(key) }
    }
    public var preventsIdle: Bool { foreground && !active.isEmpty }
}
