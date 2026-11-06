import Foundation
import Photos
import UniformTypeIdentifiers
import PhotoBridgeCore

/// V4 direct importer. Each control request represents exactly one media file.
/// The request is acknowledged only after PhotoKit has committed that file to
/// the native Photos album.
@MainActor
final class NativePhotoImportService: ObservableObject {
    private struct PendingItem {
        let ordinal: Int
        let relativePath: String
        let filename: String
        let uniformTypeIdentifier: String
        let resourceType: PHAssetResourceType
    }

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
            var createdIdentifiers: [String] = []
            createdIdentifiers.reserveCapacity(total)
            for range in DirectImportBatching.ranges(total: total) {
                try Task.checkCancellation()
                var items: [PendingItem] = []
                items.reserveCapacity(range.count)
                for ordinal in range.map({ $0 + 1 }) {
                    let marker = root.appendingPathComponent(String(format: "%06d/item.json", ordinal))
                    let value = try await waitForMarker(at: marker)
                    items.append(try pendingItem(from: value, session: session, ordinal: ordinal))
                }
                createdIdentifiers.append(contentsOf: try await importBatch(items))
                for ordinal in items.map(\.ordinal) {
                    publish(DirectImportProgress(sessionID: session, completed: ordinal, total: total, phase: "IMPORTING"))
                }
            }
            publish(DirectImportProgress(sessionID: session, completed: total, total: total, phase: "VERIFYING"))
            try verifyAlbumOrder(expectedIdentifiers: createdIdentifiers)
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

    private func pendingItem(from value: [String: Any], session: String, ordinal: Int) throws -> PendingItem {
        guard value["sessionID"] as? String == session,
              value["ordinal"] as? Int == ordinal,
              let relativePath = value["relativePath"] as? String,
              let filename = value["filename"] as? String,
              !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "收到的照片顺序信息无效"])
        }
        let pathExtension = URL(fileURLWithPath: filename).pathExtension
        let uti = UTType(filenameExtension: pathExtension)?.identifier ?? "public.data"
        let isVideo = ["mov", "mp4", "m4v"].contains(pathExtension.lowercased())
        return PendingItem(ordinal: ordinal, relativePath: relativePath, filename: filename,
                           uniformTypeIdentifier: uti, resourceType: isVideo ? .video : .photo)
    }

    private func importBatch(_ items: [PendingItem]) async throws -> [String] {
        guard let album else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建系统相册"])
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var prepared: [(PendingItem, URL)] = []
        prepared.reserveCapacity(items.count)
        for item in items {
            let file = directory.appendingPathComponent(item.relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw NSError(domain: "PhotoBridge.DirectImport", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "收件文件不可用"])
            }
            prepared.append((item, file))
        }
        var identifiers: [String] = []
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                guard let albumRequest = PHAssetCollectionChangeRequest(for: album) else { return }
                var placeholders: [PHObjectPlaceholder] = []
                placeholders.reserveCapacity(prepared.count)
                for (item, file) in prepared {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    options.originalFilename = item.filename
                    options.uniformTypeIdentifier = item.uniformTypeIdentifier
                    request.addResource(with: item.resourceType, fileURL: file, options: options)
                    if let placeholder = request.placeholderForCreatedAsset {
                        placeholders.append(placeholder)
                        identifiers.append(placeholder.localIdentifier)
                    }
                }
                albumRequest.addAssets(placeholders as NSArray)
            }, completionHandler: { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NSError(domain: "PhotoBridge.DirectImport", code: 5, userInfo: [NSLocalizedDescriptionKey: "照片写入失败"])) }
            })
        }
        return identifiers
    }

    private func verifyAlbumOrder(expectedIdentifiers: [String]) throws {
        guard let album, DirectOrderVerification.matches(expected: expectedIdentifiers,
                                                         actual: Self.identifiers(in: album)) else {
            throw NSError(domain: "PhotoBridge.DirectImport", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "导入后的相册顺序核验失败"])
        }
    }

    private static func identifiers(in album: PHAssetCollection) -> [String] {
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var identifiers: [String] = []
        identifiers.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
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
