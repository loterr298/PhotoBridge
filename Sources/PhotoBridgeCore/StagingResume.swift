import Foundation
import CryptoKit

public struct StagingResourceSource: Codable, Equatable {
    public let resourceType: Int
    public let originalFilename: String
    public let uniformTypeIdentifier: String
    public init(resourceType: Int, originalFilename: String, uniformTypeIdentifier: String) {
        self.resourceType = resourceType; self.originalFilename = originalFilename; self.uniformTypeIdentifier = uniformTypeIdentifier
    }
}

public struct StagingAssetSource: Codable, Equatable {
    public let identifier: String
    public let modificationDate: Date?
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mediaType: Int
    public let mediaSubtypes: UInt64
    public let resources: [StagingResourceSource]
    public init(identifier: String, modificationDate: Date?, creationDate: Date?, pixelWidth: Int,
                pixelHeight: Int, mediaType: Int, mediaSubtypes: UInt64, resources: [StagingResourceSource]) {
        self.identifier = identifier; self.modificationDate = modificationDate; self.creationDate = creationDate
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes; self.resources = resources
    }
}

public struct StagingPlan: Codable, Equatable {
    public let schemaVersion: String
    public let sessionID: String
    public let sourceOrder: OrderSnapshot
    public let assets: [StagingAssetSource]
    public init(sessionID: String, sourceOrder: OrderSnapshot, assets: [StagingAssetSource]) {
        schemaVersion = "1.0.0"; self.sessionID = sessionID; self.sourceOrder = sourceOrder; self.assets = assets
    }
    public func validate() throws {
        guard schemaVersion == "1.0.0", UUID(uuidString: sessionID) != nil,
              sourceOrder.authorization == "full", sourceOrder.fetchMode == "nil-options", !assets.isEmpty,
              assets.count == sourceOrder.members.count, Set(assets.map(\.identifier)).count == assets.count else {
            throw ExportError.invalidManifest("Invalid staging plan")
        }
        for (i, asset) in assets.enumerated() {
            guard !asset.identifier.isEmpty, sourceOrder.members[i].ordinal == i + 1,
                  sourceOrder.members[i].localIdentifier == asset.identifier,
                  sourceOrder.members[i].creationDate == asset.creationDate,
                  asset.modificationDate?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  asset.creationDate?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  asset.pixelWidth >= 0, asset.pixelHeight >= 0, asset.mediaType > 0, !asset.resources.isEmpty,
                  asset.resources.allSatisfy({ $0.resourceType > 0 && !$0.originalFilename.isEmpty && !$0.uniformTypeIdentifier.isEmpty }) else {
                throw ExportError.invalidManifest("Invalid staging source member/catalog")
            }
        }
    }
    public func validateCurrent(albumIdentifier: String, albumName: String, assets current: [StagingAssetSource], requireEditVersion: Bool = true) throws {
        try validate()
        guard sourceOrder.albumIdentifier == albumIdentifier, sourceOrder.albumName == albumName,
              assets == current, !requireEditVersion || assets.allSatisfy({ $0.modificationDate != nil }) else {
            throw ExportError.invalidManifest("相簿、顺序、编辑状态或资源目录已变化，或编辑标记不可用；不能继续旧暂存")
        }
    }
}

private struct StagingCheckpoint: Codable {
    let schemaVersion: String
    let sessionID: String
    let planSHA256: String
    let ordinal: Int
    let resource: ExportResource
}

public enum StagingResume {
    public static func requireDirectory(_ directory: URL) throws {
        guard directory.isFileURL,
              try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ExportError.invalidManifest("Staging root must be a real directory")
        }
    }
    private static func regular(_ relative: String, in directory: URL, maximum: Int? = nil) throws -> URL {
        try requireDirectory(directory)
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw ExportError.invalidManifest("Unsafe staging path")
        }
        var path = directory
        for (i, component) in parts.enumerated() {
            path.appendPathComponent(String(component))
            let a = try FileManager.default.attributesOfItem(atPath: path.path)
            let last = i == parts.count - 1
            guard a[.type] as? FileAttributeType == (last ? .typeRegular : .typeDirectory),
                  !last || (a[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw ExportError.invalidManifest("Staging symlink/nonregular/multiple-link path rejected")
            }
            if last, let maximum, (a[.size] as? NSNumber)?.uint64Value ?? UInt64.max > UInt64(maximum) {
                throw ExportError.invalidManifest("Staging metadata exceeds bound")
            }
        }
        return path
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        // Foundation numeric dates preserve subsecond edit versions; exchange manifests remain ISO8601.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    public static func prepare(plan: StagingPlan, in directory: URL) throws -> String {
        try plan.validate(); try requireDirectory(directory)
        guard UUID(uuidString: directory.lastPathComponent) == UUID(uuidString: plan.sessionID) else {
            throw ExportError.invalidManifest("Staging session/path mismatch")
        }
        let raw = try encode(plan)
        guard raw.count <= 64 * 1024 * 1024 else { throw ExportError.invalidManifest("Staging plan exceeds bound") }
        try raw.write(to: directory.appendingPathComponent("staging-plan.json"), options: .withoutOverwriting)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("resource-records"), withIntermediateDirectories: false)
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
    public static func load(in directory: URL) throws -> (plan: StagingPlan, digest: String) {
        try requireDirectory(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard !names.contains("album-order.json") else { throw ExportError.invalidManifest("已完成的暂存无需继续") }
        let raw = try Data(contentsOf: regular("staging-plan.json", in: directory, maximum: 64 * 1024 * 1024))
        let plan = try JSONDecoder().decode(StagingPlan.self, from: raw); try plan.validate()
        guard UUID(uuidString: directory.lastPathComponent) == UUID(uuidString: plan.sessionID) else {
            throw ExportError.invalidManifest("Staging session/path mismatch")
        }
        return (plan, SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined())
    }
    private static func validate(_ r: ExportResource, ordinal: Int, plan: StagingPlan) throws {
        guard ordinal > 0, ordinal <= plan.assets.count else { throw ExportError.invalidManifest("Invalid checkpoint ordinal") }
        let sources = plan.assets[ordinal - 1].resources
        guard r.resourceIndex > 0, r.resourceIndex <= sources.count else { throw ExportError.invalidManifest("Invalid checkpoint resource") }
        let source = sources[r.resourceIndex - 1]
        guard r.resourceType == source.resourceType, r.originalFilename == source.originalFilename,
              r.uniformTypeIdentifier == source.uniformTypeIdentifier,
              r.storedRelativePath == ResourcePaths.make(ordinal: ordinal, resourceIndex: r.resourceIndex, originalFilename: source.originalFilename),
              r.byteCount > 0, r.sha256.count == 64, r.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ExportError.invalidManifest("Checkpoint does not match resource plan")
        }
    }
    private static func verify(_ resource: ExportResource, in directory: URL) throws {
        let file = try regular(resource.storedRelativePath, in: directory)
        let receipt = try ProbeFiles.inspect(file)
        guard receipt.byteCount == resource.byteCount, receipt.sha256 == resource.sha256 else {
            throw ExportError.invalidManifest("暂存资源大小或 SHA-256 不一致，停止继续")
        }
    }
    public static func record(_ resource: ExportResource, ordinal: Int, plan: StagingPlan, digest: String, in directory: URL) throws {
        try validate(resource, ordinal: ordinal, plan: plan); try verify(resource, in: directory)
        let records = directory.appendingPathComponent("resource-records"); try requireDirectory(records)
        let final = records.appendingPathComponent(String(format: "%06d-%04d.json", ordinal, resource.resourceIndex))
        let part = final.appendingPathExtension("part")
        let checkpoint = StagingCheckpoint(schemaVersion: "1.0.0", sessionID: plan.sessionID, planSHA256: digest, ordinal: ordinal, resource: resource)
        try encode(checkpoint).write(to: part, options: .withoutOverwriting)
        try StagingFiles.commit(part: part, destination: final)
    }
    public static func reusable(in directory: URL, plan: StagingPlan, digest: String) throws -> [String: ExportResource] {
        let actual = try load(in: directory)
        guard actual.plan == plan, actual.digest == digest else { throw ExportError.invalidManifest("Staging plan changed") }
        let records = directory.appendingPathComponent("resource-records"); try requireDirectory(records)
        var result: [String: ExportResource] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: records.path) where name.hasSuffix(".json") {
            let raw = try Data(contentsOf: regular("resource-records/" + name, in: directory, maximum: 1024 * 1024))
            let c = try JSONDecoder().decode(StagingCheckpoint.self, from: raw)
            guard c.schemaVersion == "1.0.0", c.sessionID == plan.sessionID, c.planSHA256 == digest,
                  name == String(format: "%06d-%04d.json", c.ordinal, c.resource.resourceIndex), result[c.resource.storedRelativePath] == nil else {
                throw ExportError.invalidManifest("Foreign/ambiguous staging checkpoint")
            }
            try validate(c.resource, ordinal: c.ordinal, plan: plan); try verify(c.resource, in: directory)
            result[c.resource.storedRelativePath] = c.resource
        }
        return result
    }
    public static func copy(_ resource: ExportResource, from previous: URL, to directory: URL) throws {
        let old = previous.resolvingSymlinksInPath().standardizedFileURL.path
        let new = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard old != new, !new.hasPrefix(old + "/"), !old.hasPrefix(new + "/") else {
            throw ExportError.invalidManifest("Recovery must use a separate new session")
        }
        try requireDirectory(directory); try verify(resource, in: previous)
        let components = resource.storedRelativePath.split(separator: "/"); var parent = directory
        for component in components.dropLast() {
            parent.appendPathComponent(String(component))
            if !FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
            try requireDirectory(parent)
        }
        let final = directory.appendingPathComponent(resource.storedRelativePath); let part = final.appendingPathExtension("part")
        guard !FileManager.default.fileExists(atPath: final.path), !FileManager.default.fileExists(atPath: part.path) else {
            throw ExportError.invalidManifest("Recovery destination already exists")
        }
        try FileManager.default.copyItem(at: previous.appendingPathComponent(resource.storedRelativePath), to: part)
        let receipt = try ProbeFiles.inspect(part)
        guard receipt.byteCount == resource.byteCount, receipt.sha256 == resource.sha256 else { throw ExportError.invalidManifest("Copied staging resource changed") }
        try StagingFiles.commit(part: part, destination: final)
    }
}
