import Foundation
import CryptoKit
import Darwin

public struct RestoreRecoveryPlan: Codable, Equatable {
    public let schemaVersion: String
    public let attemptID: String
    public let inboxSessionID: String
    public let manifestSHA256: String
    public let requestSHA256: String
    public let sourceAlbumID: String
    public let sourceAssetIDs: [String]
    public let title: String
    public let allowTimestampRewrite: Bool
    public init(inboxSessionID: String, manifestSHA256: String, requestSHA256: String, sourceAlbumID: String,
                sourceAssetIDs: [String], title: String, allowTimestampRewrite: Bool) {
        schemaVersion = "1.0.0"; attemptID = UUID().uuidString; self.inboxSessionID = inboxSessionID
        self.manifestSHA256 = manifestSHA256; self.requestSHA256 = requestSHA256; self.sourceAlbumID = sourceAlbumID
        self.sourceAssetIDs = sourceAssetIDs; self.title = title; self.allowTimestampRewrite = allowTimestampRewrite
    }
    public func validate() throws {
        func hash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { "0123456789abcdef".contains($0) } }
        guard schemaVersion == "1.0.0", UUID(uuidString: attemptID) != nil, UUID(uuidString: inboxSessionID) != nil,
              hash(manifestSHA256), hash(requestSHA256), !sourceAlbumID.isEmpty, !sourceAssetIDs.isEmpty,
              Set(sourceAssetIDs).count == sourceAssetIDs.count, sourceAssetIDs.allSatisfy({ !$0.isEmpty }),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 128 else {
            throw ExportError.invalidManifest("Invalid Photos recovery plan")
        }
    }
}

public struct RestoreRecoveryState {
    public let plan: RestoreRecoveryPlan
    public let albumID: String?
    public let assetIDs: [String]
    public let verifiedVersions: [String: Date]
    public func validateObserved(albumID observedAlbum: String?, title: String?, memberIDs: [String], visibleAssetIDs: [String]) throws {
        guard let albumID, observedAlbum == albumID, title == plan.title,
              memberIDs == assetIDs, Set(visibleAssetIDs) == Set(assetIDs), visibleAssetIDs.count == assetIDs.count else {
            throw ExportError.invalidManifest("已记录副本不可见，或目标相簿/名称/成员/顺序改变；不自动重试创建")
        }
    }
}

private struct RestoreRecoveryEvent: Codable {
    let schemaVersion: String
    let attemptID: String
    let planSHA256: String
    let kind: String
    let ordinal: Int
    let sourceID: String?
    let createdID: String?
    let modified: Date?
}

public final class RestoreRecoveryLease {
    private var descriptor: Int32
    fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
    public func release() { if descriptor >= 0 { close(descriptor); descriptor = -1 } }
    deinit { release() }
}

public final class RestoreRecoveryStore {
    public let directory: URL
    public let plan: RestoreRecoveryPlan
    private let planData: Data
    private let digest: String
    private static let fm = FileManager.default
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func regularData(_ url: URL) throws -> Data {
        let a = try fm.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular, (a[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = a[.size] as? NSNumber, size.uint64Value <= 64 * 1024 * 1024 else {
            throw ExportError.invalidManifest("Invalid recovery journal file")
        }
        return try Data(contentsOf: url)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    /// Metadata only: exclusive final commit, unique scratch file, preserve all interrupted scratch files.
    public static func writeNewMetadata(_ data: Data, to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension == "json", !destination.path.contains("\0"), data.count <= 64 * 1024 * 1024 else {
            throw ExportError.invalidManifest("Invalid recovery metadata destination")
        }
        try StagingResume.requireDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString)
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    public static func create(plan: RestoreRecoveryPlan, in inbox: URL) throws -> RestoreRecoveryStore {
        try plan.validate(); try StagingResume.requireDirectory(inbox)
        guard plan.inboxSessionID == inbox.lastPathComponent else { throw ExportError.invalidManifest("Recovery inbox mismatch") }
        let dir = inbox.appendingPathComponent("restore-recovery")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        try writeNewMetadata(encode(plan), to: dir.appendingPathComponent("plan.json"))
        return try RestoreRecoveryStore(in: inbox)
    }
    public init(in inbox: URL) throws {
        try StagingResume.requireDirectory(inbox)
        directory = inbox.appendingPathComponent("restore-recovery"); try StagingResume.requireDirectory(directory)
        planData = try Self.regularData(directory.appendingPathComponent("plan.json"))
        plan = try JSONDecoder().decode(RestoreRecoveryPlan.self, from: planData); try plan.validate()
        guard plan.inboxSessionID == inbox.lastPathComponent else { throw ExportError.invalidManifest("Recovery inbox mismatch") }
        digest = Self.sha256(planData)
    }
    public func lock() throws -> RestoreRecoveryLease {
        let fd = open(directory.appendingPathComponent("plan.json").path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { let code = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        do { try unchangedPlan() } catch { close(fd); throw error }
        return RestoreRecoveryLease(fd)
    }
    private func unchangedPlan() throws {
        try StagingResume.requireDirectory(directory)
        guard try Self.regularData(directory.appendingPathComponent("plan.json")) == planData else { throw ExportError.invalidManifest("Recovery plan changed") }
    }
    public func validateBinding(manifestSHA256: String, requestSHA256: String, allowTimestampRewrite: Bool) throws {
        try unchangedPlan()
        guard plan.manifestSHA256 == manifestSHA256, plan.requestSHA256 == requestSHA256,
              plan.allowTimestampRewrite == allowTimestampRewrite else { throw ExportError.invalidManifest("恢复来源或原始授权选项改变，不能继续") }
    }
    private func filename(_ kind: String, _ ordinal: Int) -> String {
        kind.hasPrefix("album-") ? kind + ".json" : String(format: "%06d-", ordinal) + kind.replacingOccurrences(of: "asset-", with: "") + ".json"
    }
    private func event(_ kind: String, _ ordinal: Int, names: Set<String>? = nil) throws -> RestoreRecoveryEvent? {
        let url = directory.appendingPathComponent(filename(kind, ordinal))
        let present = try names ?? Set(Self.fm.contentsOfDirectory(atPath: directory.path))
        guard present.contains(url.lastPathComponent) else { return nil }
        let e = try JSONDecoder().decode(RestoreRecoveryEvent.self, from: Self.regularData(url))
        let album = kind.hasPrefix("album-")
        guard (album && ordinal == 0) || (!album && ordinal > 0 && ordinal <= plan.sourceAssetIDs.count) else { throw ExportError.invalidManifest("Invalid recovery ordinal") }
        guard e.schemaVersion == "1.0.0", e.attemptID == plan.attemptID, e.planSHA256 == digest, e.kind == kind,
              e.ordinal == ordinal, e.sourceID == (album ? nil : plan.sourceAssetIDs[ordinal - 1]) else { throw ExportError.invalidManifest("Foreign recovery record") }
        if kind.hasSuffix("intent") {
            guard e.createdID == nil, e.modified == nil else { throw ExportError.invalidManifest("Invalid intent") }
        } else {
            guard let id = e.createdID, !id.isEmpty, !id.contains("\0"), !plan.sourceAssetIDs.contains(id), id != plan.sourceAlbumID else { throw ExportError.invalidManifest("Invalid new-copy identity") }
            if kind.hasSuffix("verified") {
                guard let date = e.modified, date.timeIntervalSinceReferenceDate.isFinite else { throw ExportError.invalidManifest("Missing verified asset version") }
            } else if e.modified != nil { throw ExportError.invalidManifest("Unexpected placeholder version") }
        }
        return e
    }
    private func write(_ kind: String, _ ordinal: Int, identifier: String? = nil, modified: Date? = nil) throws {
        try unchangedPlan()
        let album = kind.hasPrefix("album-")
        guard (album && ordinal == 0) || (!album && ordinal > 0 && ordinal <= plan.sourceAssetIDs.count) else { throw ExportError.invalidManifest("Invalid recovery ordinal") }
        if let identifier { guard !identifier.isEmpty, !identifier.contains("\0"), !plan.sourceAssetIDs.contains(identifier), identifier != plan.sourceAlbumID else { throw ExportError.invalidManifest("Cannot adopt original identity") } }
        let e = RestoreRecoveryEvent(schemaVersion: "1.0.0", attemptID: plan.attemptID, planSHA256: digest, kind: kind,
            ordinal: ordinal, sourceID: album ? nil : plan.sourceAssetIDs[ordinal - 1], createdID: identifier, modified: modified)
        try Self.writeNewMetadata(Self.encode(e), to: directory.appendingPathComponent(filename(kind, ordinal)))
    }
    public func state() throws -> RestoreRecoveryState {
        try unchangedPlan()
        var allowed: Set<String> = ["plan.json", "album-intent.json", "album-placeholder.json"]
        for i in 1...plan.sourceAssetIDs.count { for kind in ["asset-intent", "asset-placeholder", "asset-verified"] { allowed.insert(filename(kind, i)) } }
        let names = Set(try Self.fm.contentsOfDirectory(atPath: directory.path))
        for name in names where !allowed.contains(name) {
            guard name.hasPrefix(".pending-"), UUID(uuidString: String(name.dropFirst(9))) != nil else { throw ExportError.invalidManifest("Unknown recovery record") }
            _ = try Self.regularData(directory.appendingPathComponent(name))
        }
        let albumIntent = try event("album-intent", 0, names: names); let album = try event("album-placeholder", 0, names: names)
        guard (albumIntent == nil) == (album == nil) else { throw ExportError.invalidManifest("相簿事务状态不明确，缺少持久化标识；不重建相簿") }
        var ids: [String] = []; var versions: [String: Date] = [:]; var gap = false
        for i in 1...plan.sourceAssetIDs.count {
            let intent = try event("asset-intent", i, names: names); let placeholder = try event("asset-placeholder", i, names: names); let verified = try event("asset-verified", i, names: names)
            if intent == nil { guard placeholder == nil, verified == nil else { throw ExportError.invalidManifest("Missing intent") }; gap = true; continue }
            guard album != nil, !gap, let id = placeholder?.createdID, id != album?.createdID, !ids.contains(id) else {
                throw ExportError.invalidManifest("资产事务标识缺失、重复或不连续；不自动重试创建")
            }
            if i > 1, versions[ids[i - 2]] == nil { throw ExportError.invalidManifest("Earlier asset verification missing") }
            ids.append(id)
            if let verified { guard verified.createdID == id else { throw ExportError.invalidManifest("Verified identity mismatch") }; versions[id] = verified.modified }
        }
        return RestoreRecoveryState(plan: plan, albumID: album?.createdID, assetIDs: ids, verifiedVersions: versions)
    }
    public func beginAlbum() throws {
        let current = try state(); guard current.albumID == nil, current.assetIDs.isEmpty else { throw ExportError.invalidManifest("Album already recorded") }
        try write("album-intent", 0)
    }
    public func recordAlbumPlaceholder(_ identifier: String) throws {
        guard try event("album-intent", 0) != nil else { throw ExportError.invalidManifest("Album intent required") }
        try write("album-placeholder", 0, identifier: identifier)
    }
    public func beginAsset(ordinal: Int) throws {
        let current = try state()
        guard current.albumID != nil, ordinal > 0, ordinal <= plan.sourceAssetIDs.count,
              ordinal == current.assetIDs.count + 1, current.verifiedVersions.count == current.assetIDs.count else { throw ExportError.invalidManifest("Not a new verified-prefix transaction") }
        try write("asset-intent", ordinal)
    }
    public func recordAssetPlaceholder(ordinal: Int, identifier: String) throws {
        guard ordinal > 0, ordinal <= plan.sourceAssetIDs.count, try event("asset-intent", ordinal) != nil else { throw ExportError.invalidManifest("Asset intent required") }
        guard try event("album-placeholder", 0)?.createdID != identifier else { throw ExportError.invalidManifest("Album/asset identity collision") }
        if ordinal > 1 {
            for previous in 1..<ordinal {
                guard try event("asset-placeholder", previous)?.createdID != identifier else { throw ExportError.invalidManifest("Duplicate created asset identity") }
            }
        }
        try write("asset-placeholder", ordinal, identifier: identifier)
    }
    public func recordVerified(ordinal: Int, identifier: String, modified: Date) throws {
        let current = try state()
        guard ordinal > 0, ordinal <= current.assetIDs.count, current.assetIDs[ordinal - 1] == identifier,
              modified.timeIntervalSinceReferenceDate.isFinite else { throw ExportError.invalidManifest("Cannot verify unknown asset") }
        if let previous = current.verifiedVersions[identifier] {
            guard previous == modified else { throw ExportError.invalidManifest("已回读副本在两次运行之间被修改，停止继续") }; return
        }
        try write("asset-verified", ordinal, identifier: identifier, modified: modified)
    }
}
