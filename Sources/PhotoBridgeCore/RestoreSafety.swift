import Foundation
import CryptoKit

public enum RestoreSafety {
    /// PhotoKit database date, not EXIF. Allow only sub-millisecond platform representation noise.
    public static func verifyCreationDate(expected: Date?, observed: Date?) throws {
        if expected == nil && observed == nil { return }
        guard let expected, let observed, expected.timeIntervalSince1970.isFinite, observed.timeIntervalSince1970.isFinite,
              abs(expected.timeIntervalSince(observed)) <= 0.001 else {
            throw ExportError.invalidManifest("导入后的照片拍摄日期与来源清单不符")
        }
    }

    public static func decodeManifest(data: Data, expectedSHA256: String) throws -> AlbumExportManifest {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw ExportError.invalidManifest("Restore manifest SHA-256 mismatch") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(AlbumExportManifest.self, from: data)
        try manifest.validate()
        return manifest
    }
    public static func verifyResource(_ resource: ExportResource, in directory: URL, checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let components = resource.storedRelativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") }) else {
            throw ExportError.invalidManifest("Unsafe restore path")
        }
        var current = directory
        let manager = FileManager.default
        guard try manager.attributesOfItem(atPath: current.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ExportError.invalidManifest("Restore root must be a real directory")
        }
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component))
            let attributes = try manager.attributesOfItem(atPath: current.path)
            let required: FileAttributeType = index == components.count - 1 ? .typeRegular : .typeDirectory
            guard attributes[.type] as? FileAttributeType == required else {
                throw ExportError.invalidManifest("Restore path is not a regular file/directory")
            }
        }
        let receipt = try ProbeFiles.inspect(current, checkCancellation: checkCancellation)
        guard receipt.byteCount == resource.byteCount && receipt.sha256 == resource.sha256 else {
            throw ExportError.invalidManifest("Restore resource size/SHA-256 mismatch")
        }
    }

    /// Permanent claim before any Photos write: an ambiguous crash must not silently duplicate assets.
    public static func claimOnce(in directory: URL) throws {
        let destination = directory.appendingPathComponent("restore-started.json")
        let part = destination.appendingPathExtension("part")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError.invalidManifest("This restore has already been attempted; inspect its journal")
        }
        try Data("{\"state\":\"ATTEMPT_CLAIMED\",\"automaticReplay\":false}".utf8).write(to: part, options: .withoutOverwriting)
        try StagingFiles.commit(part: part, destination: destination)
    }

    public static func sameResources(expected: [ExportResource], observed: [ExportResource]) -> Bool {
        func counts(_ resources: [ExportResource]) -> [String: Int] {
            var result: [String: Int] = [:]
            for resource in resources {
                // JSON encoding prevents delimiter collisions in filenames/UTIs.
                let fields = [String(resource.resourceType), resource.originalFilename, resource.uniformTypeIdentifier,
                              String(resource.byteCount), resource.sha256]
                let key = String(data: try! JSONEncoder().encode(fields), encoding: .utf8)!
                result[key, default: 0] += 1
            }
            return result
        }
        return counts(expected) == counts(observed)
    }

    public static func verifyOrder(sourceIDs: [String], mapping: [String: String], observed: [String]) throws {
        guard !sourceIDs.isEmpty, Set(sourceIDs).count == sourceIDs.count,
              Set(mapping.keys) == Set(sourceIDs), Set(mapping.values).count == sourceIDs.count,
              !mapping.values.contains(""), observed == sourceIDs.compactMap({ mapping[$0] }) else {
            throw ExportError.invalidManifest("Restored membership/order/mapping mismatch")
        }
    }
}
