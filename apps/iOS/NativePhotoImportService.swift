import Foundation
import Photos
import UniformTypeIdentifiers
import PhotoBridgeCore

/// V4 direct importer. Each control request represents exactly one media file.
/// The request is acknowledged only after PhotoKit has committed that file to
/// the native Photos album.
@MainActor
final class NativePhotoImportService: ObservableObject {
    @Published private(set) var directProgress: DirectImportProgress?
    var onProgress: ((DirectImportProgress) -> Void)?
    private var album: PHAssetCollection?
    private var albumTitle = ""
    private var sessionID = ""
    private var sessionTask: Task<Void, Never>?

    func startSession(session: String, title: String, total: Int) {
        sessionTask?.cancel()
        let initial = DirectImportProgress(sessionID: session, completed: 0, total: total, phase: "IMPORTING")
        directProgress = initial
        onProgress?(initial)
        sessionTask = Task { [weak self] in
            await self?.runSession(session: session, title: title, total: total)
        }
    }

    func stopSession() {
        sessionTask?.cancel()
        sessionTask = nil
    }

    private func runSession(session: String, title: String, total: Int) async {
        do {
            guard UUID(uuidString: session) != nil, !title.isEmpty, total > 0 else {
                throw NSError(domain: "PhotoBridge.DirectImport", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: "导入任务信息无效"])
            }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw NSError(domain: "PhotoBridge.DirectImport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "请允许访问全部照片"])
            }
            sessionID = session
            albumTitle = String(title.prefix(128))
            album = try await createAlbum(title: albumTitle)
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DirectInbox", isDirectory: true)
                .appendingPathComponent(session, isDirectory: true)
            for ordinal in 1...total {
                try Task.checkCancellation()
                let marker = root.appendingPathComponent(String(format: "%06d/item.json", ordinal))
                let value = try await waitForMarker(at: marker)
                guard value["sessionID"] as? String == session,
                      value["ordinal"] as? Int == ordinal,
                      let relativePath = value["relativePath"] as? String,
                      let filename = value["filename"] as? String else {
                    throw NSError(domain: "PhotoBridge.DirectImport", code: 9,
                                  userInfo: [NSLocalizedDescriptionKey: "收到的照片顺序信息无效"])
                }
                let uti = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)?.identifier ?? "public.data"
                let resourceType = ["mov", "mp4", "m4v"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) ? 2 : 1
                try await importItem(session: session, ordinal: ordinal, title: albumTitle,
                                     relativePath: relativePath, filename: filename,
                                     uniformTypeIdentifier: uti, resourceType: resourceType)
                publish(DirectImportProgress(sessionID: session, completed: ordinal, total: total, phase: "IMPORTING"))
            }
            publish(DirectImportProgress(sessionID: session, completed: total, total: total, phase: "COMMITTED"))
        } catch is CancellationError {
            return
        } catch {
            publish(DirectImportProgress(sessionID: session,
                                         completed: directProgress?.progress.completed ?? 0,
                                         total: total, phase: "FAILED"))
        }
    }

    private func publish(_ value: DirectImportProgress) {
        directProgress = value
        onProgress?(value)
    }

    private func waitForMarker(at url: URL) async throws -> [String: Any] {
        while !Task.isCancelled {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
               let data = try? Data(contentsOf: url),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return value
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw CancellationError()
    }

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
