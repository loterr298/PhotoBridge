import Foundation
import Photos

/// V4 direct importer. Each control request represents exactly one media file.
/// The request is acknowledged only after PhotoKit has committed that file to
/// the native Photos album.
@MainActor
final class NativePhotoImportService: ObservableObject {
    private var album: PHAssetCollection?
    private var albumTitle = ""
    private var sessionID = ""

    func importItem(session: String, ordinal: Int, title: String, relativePath: String,
                    filename: String, uniformTypeIdentifier: String, resourceType: Int) async throws {
        guard UUID(uuidString: session) != nil, ordinal > 0,
              !title.isEmpty, title.count <= 128,
              !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "导入项目无效"])
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "请允许访问全部照片"])
        }
        if sessionID != session || album == nil {
            sessionID = session; albumTitle = title
            album = try await createAlbum(title: title)
        }
        guard let album else { throw NSError(domain: "PhotoBridge.DirectImport", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法创建系统相册"]) }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = directory.appendingPathComponent(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 4, userInfo: [NSLocalizedDescriptionKey: "收件文件不可用"])
        }
        let resourceType = PHAssetResourceType(rawValue: resourceType) ?? .photo
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                options.originalFilename = filename
                options.uniformTypeIdentifier = uniformTypeIdentifier
                request.addResource(with: resourceType, fileURL: file, options: options)
                if let placeholder = request.placeholderForCreatedAsset {
                    albumRequest.addAssets([placeholder] as NSArray)
                }
            }, completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "PhotoBridge.DirectImport", code: 5, userInfo: [NSLocalizedDescriptionKey: "照片写入失败"])) }
            })
        }
    }

    private func createAlbum(title: String) async throws -> PHAssetCollection {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var existing: PHAssetCollection?
        collections.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == title { existing = collection; stop.pointee = true }
        }
        if let existing { return existing }
        var placeholder: PHObjectPlaceholder?
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title).placeholderForCreatedAssetCollection
            }, completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "PhotoBridge.DirectImport", code: 6, userInfo: [NSLocalizedDescriptionKey: "系统相册创建失败"])) }
            })
        }
        guard let id = placeholder?.localIdentifier,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 7, userInfo: [NSLocalizedDescriptionKey: "系统相册不可见"])
        }
        return collection
    }
}
