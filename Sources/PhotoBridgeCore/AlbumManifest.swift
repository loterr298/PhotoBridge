import Foundation

public enum ExportError: LocalizedError {
    case invalidManifest(String)
    public var errorDescription: String? {
        switch self { case .invalidManifest(let message): return message }
    }
}

public enum ResourcePaths {
    public static func make(ordinal: Int, resourceIndex: Int, originalFilename: String) -> String {
        let candidate = (originalFilename as NSString).pathExtension
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let ext = !candidate.isEmpty && candidate.count <= 10 && candidate.unicodeScalars.allSatisfy(allowed.contains) ? candidate : "bin"
        return String(format: "Resources/%06d/%04d.", ordinal, resourceIndex) + ext
    }
}

public struct ExportResource: Codable, Equatable {
    public let resourceIndex: Int
    /// Preserve raw PhotoKit type numbers, including future types; never infer from filename.
    public let resourceType: Int
    public let originalFilename: String
    public let uniformTypeIdentifier: String
    public let storedRelativePath: String
    public let sha256: String
    public let byteCount: Int
    public init(resourceIndex: Int, resourceType: Int, originalFilename: String, uniformTypeIdentifier: String,
                storedRelativePath: String, sha256: String, byteCount: Int) {
        self.resourceIndex = resourceIndex; self.resourceType = resourceType; self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier; self.storedRelativePath = storedRelativePath
        self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct ExportAsset: Codable, Equatable {
    public let ordinal: Int
    public let resourceGroupId: String
    public let sourceAssetLocalIdentifier: String
    public let originalPhotoLibraryCreationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mediaType: Int
    public let mediaSubtypes: UInt64
    public let resources: [ExportResource]
    public init(ordinal: Int, resourceGroupId: String, sourceAssetLocalIdentifier: String,
                originalPhotoLibraryCreationDate: Date?, pixelWidth: Int, pixelHeight: Int,
                mediaType: Int, mediaSubtypes: UInt64, resources: [ExportResource]) {
        self.ordinal = ordinal; self.resourceGroupId = resourceGroupId; self.sourceAssetLocalIdentifier = sourceAssetLocalIdentifier
        self.originalPhotoLibraryCreationDate = originalPhotoLibraryCreationDate
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes; self.resources = resources
    }
}

public struct AlbumExportManifest: Codable {
    public let schemaVersion: String
    public let kind: String
    public let sessionID: String
    public let sourceOrder: OrderSnapshot
    public let assets: [ExportAsset]
    public let status: String
    public let intervalSeconds: Int
    public let timestampScope: String
    public let restorationStatus: String
    public init(sessionID: String, sourceOrder: OrderSnapshot, assets: [ExportAsset]) {
        schemaVersion = "1.0.0"; kind = "PhotoBridgeOriginalExport"; self.sessionID = sessionID
        self.sourceOrder = sourceOrder; self.assets = assets; status = "staged"
        intervalSeconds = 5; timestampScope = "new-Mac-copies-filesystem-only"
        restorationStatus = "NOT_RUN: staged resource backup only"
    }
    public func logicalTime(ordinal: Int) -> Date {
        sourceOrder.capturedAt.addingTimeInterval(Double(ordinal - 1) * Double(intervalSeconds))
    }
    public func validate() throws {
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw ExportError.invalidManifest(message) }
        }
        try check(schemaVersion == "1.0.0" && kind == "PhotoBridgeOriginalExport" && status == "staged", "Unsupported manifest")
        try check(UUID(uuidString: sessionID) != nil && intervalSeconds == 5, "Invalid session or time policy")
        try check(timestampScope == "new-Mac-copies-filesystem-only", "Unsafe time policy")
        try check(sourceOrder.authorization == "full", "Complete album requires full library permission")
        let members = sourceOrder.members
        try check(!members.isEmpty && members.count == assets.count, "Missing asset groups")
        try check(Set(members.map(\.localIdentifier)).count == members.count, "Duplicate source members")
        var paths = Set<String>(); var groups = Set<String>()
        for (index, asset) in assets.enumerated() {
            try check(asset.ordinal == index + 1 && members[index].ordinal == index + 1, "Noncontiguous order")
            try check(asset.sourceAssetLocalIdentifier == members[index].localIdentifier, "Source membership changed")
            try check(UUID(uuidString: asset.resourceGroupId) != nil && groups.insert(asset.resourceGroupId).inserted, "Duplicate/invalid group")
            try check(!asset.resources.isEmpty, "No accessible resources")
            for (resourceIndex, resource) in asset.resources.enumerated() {
                let expected = ResourcePaths.make(ordinal: asset.ordinal, resourceIndex: resourceIndex + 1, originalFilename: resource.originalFilename)
                try check(resource.resourceIndex == resourceIndex + 1 && resource.storedRelativePath == expected, "Invalid resource destination")
                try check(paths.insert(resource.storedRelativePath).inserted, "Duplicate resource destination")
                try check(resource.byteCount > 0 && resource.resourceType > 0, "Invalid resource size/type")
                try check(resource.sha256.count == 64 && resource.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "Invalid SHA-256")
            }
        }
    }
    public func json() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}
