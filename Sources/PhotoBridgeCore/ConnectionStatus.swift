import Foundation

/// UI-only evidence of a recent USB round trip. Never authorizes Photos writes.
/// Uptime avoids trusting either device's wall clock. Persisted files alone are
/// insufficient: the phone requires the Mac to confirm a reply it just read.
public struct ConnectionFreshness: Sendable {
    private var confirmedAt: TimeInterval?
    public init() {}
    public mutating func confirm(now: TimeInterval) { confirmedAt = now.isFinite ? now : nil }
    public mutating func invalidate() { confirmedAt = nil }
    public func isConnected(now: TimeInterval) -> Bool {
        guard let confirmedAt, now.isFinite else { return false }
        return now >= confirmedAt && now - confirmedAt < 8
    }
}

public struct ConnectionRequest: Codable, Sendable {
    public let kind: String
    public let nonce: UUID
    public let confirmedNonce: UUID?
    public init(nonce: UUID, confirmedNonce: UUID?) {
        kind = "PhotoBridgeConnection"; self.nonce = nonce; self.confirmedNonce = confirmedNonce
    }
    public static func read(in root: URL) -> Self? {
        guard (try? StagingResume.requireDirectory(root)) != nil else { return nil }
        let url = root.appendingPathComponent("connection-request.json")
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              a[.type] as? FileAttributeType == .typeRegular,
              (a[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = a[.size] as? NSNumber, size.intValue <= 4096,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let raw = try? file.read(upToCount: 4097), raw.count <= 4096,
              let value = try? JSONDecoder().decode(Self.self, from: raw),
              value.kind == "PhotoBridgeConnection" else { return nil }
        return value
    }
}

public struct ConnectionReply: Encodable, Equatable, Sendable {
    public let kind = "PhotoBridgeConnectionReply"
    public let nonce: UUID
    public let foreground: Bool
    public func write(in root: URL) throws {
        try StagingResume.requireDirectory(root)
        let url = root.appendingPathComponent("connection-reply.json")
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard a[.type] as? FileAttributeType == .typeRegular,
                  (a[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public struct PhoneConnection: Sendable {
    private var nonce: UUID?
    private var challengeAt: TimeInterval?
    private var freshness = ConnectionFreshness()
    public init() {}
    public mutating func invalidate() { nonce = nil; challengeAt = nil; freshness.invalidate() }
    public func isConnected(now: TimeInterval) -> Bool { freshness.isConnected(now: now) }
    public mutating func receive(_ request: ConnectionRequest, now: TimeInterval, foreground: Bool) -> ConnectionReply {
        if !foreground { invalidate() }
        if nonce != request.nonce {
            if foreground, let nonce, request.confirmedNonce == nonce, let challengeAt,
               now >= challengeAt, now - challengeAt < 8 {
                freshness.confirm(now: now)
            } else { freshness.invalidate() }
            nonce = request.nonce; challengeAt = now
        }
        return ConnectionReply(nonce: request.nonce, foreground: foreground)
    }
}
