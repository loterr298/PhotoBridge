import SwiftUI
import Photos
import PhotoBridgeCore

private struct RestoreInboxRequest: Decodable {
    let schemaVersion: String
    let kind: String
    let sessionID: String
    let state: String
    let sourceManifestSHA256: String
    let assetCount: Int
    let resourceCount: Int
    let byteCount: Int
}

@MainActor final class RestoreService: ObservableObject {
    @Published var sessions: [String] = []
    @Published var busy = false
    @Published var ready = false
    @Published var message = "请先由 Mac 通过 USB 发送已校验备份，然后刷新收件箱。"
    @Published var completed = 0
    private var selected: URL?
    private var manifest: AlbumExportManifest?
    private var manifestData: Data?
    private var requestData: Data?
    private var stopRequested = false
    private var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RestoreInbox")
    }

    func refresh() {
        guard !busy else { return }
        invalidate()
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            sessions = try FileManager.default.contentsOfDirectory(atPath: inbox.path)
                .filter { UUID(uuidString: $0) != nil }.sorted()
        } catch { message = "无法读取收件箱：\(error.localizedDescription)" }
    }
    func invalidate() { ready = false; manifest = nil; selected = nil; manifestData = nil; requestData = nil }
    func requestStop() { stopRequested = true }
    private func checkPermissionAndStop() throws {
        guard !stopRequested && !Task.isCancelled else { throw ExportError.invalidManifest("已在事务边界停止；不会自动重复导入") }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw ExportError.invalidManifest("校验完整相簿需要全部照片权限，请在设置中允许")
        }
    }
    private func readJSONFile(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
            throw ExportError.invalidManifest("无效或过大的恢复清单")
        }
        return try Data(contentsOf: url)
    }
    func preflight(session: String) async {
        guard !busy else { return }
        invalidate(); busy = true; stopRequested = false; completed = 0
        defer { busy = false }
        do {
            try checkPermissionAndStop()
            guard UUID(uuidString: session) != nil else { throw ExportError.invalidManifest("请选择有效收件会话") }
            let directory = inbox.appendingPathComponent(session)
            guard try FileManager.default.attributesOfItem(atPath: inbox.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExportError.invalidManifest("收件根目录不是普通目录")
            }
            guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExportError.invalidManifest("收件会话必须为真实目录")
            }
            let requestRaw = try readJSONFile(directory.appendingPathComponent("restore-request.json"))
            let request = try JSONDecoder().decode(RestoreInboxRequest.self, from: requestRaw)
            let manifestURL = directory.appendingPathComponent("album-order.json")
            let raw = try readJSONFile(manifestURL)
            let candidate = try RestoreSafety.decodeManifest(data: raw, expectedSHA256: request.sourceManifestSHA256)
            let resources = candidate.assets.flatMap(\.resources)
            var totalBytes = 0
            for resource in resources {
                let (sum, overflow) = totalBytes.addingReportingOverflow(resource.byteCount)
                guard !overflow else { throw ExportError.invalidManifest("资源总大小超出支持范围") }
                totalBytes = sum
            }
            guard request.schemaVersion == "1.0.0", request.kind == "PhotoBridgeRestoreRequest",
                  request.sessionID == session, request.state == "USB_VERIFIED",
                  request.assetCount == candidate.assets.count, request.resourceCount == resources.count,
                  request.byteCount == totalBytes else {
                throw ExportError.invalidManifest("USB 收件标记或资源数量/hash 不一致")
            }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-started.json").path) else {
                throw ExportError.invalidManifest("此会话已尝试写入照片库，请查看恢复日志；不自动重复导入")
            }
            for asset in candidate.assets {
                try checkPermissionAndStop()
                guard asset.pixelWidth >= 0, asset.pixelHeight >= 0, asset.mediaType > 0,
                      asset.resources.allSatisfy({ !$0.originalFilename.isEmpty && !$0.uniformTypeIdentifier.isEmpty && PHAssetResourceType(rawValue: $0.resourceType) != nil }),
                      PHAssetCreationRequest.supportsAssetResourceTypes(asset.resources.map { NSNumber(value: $0.resourceType) }) else {
                    throw ExportError.invalidManifest("位置 \(asset.ordinal) 的完整资源组合不受本机 PhotoKit 支持，未丢弃任何附件，未写入照片库")
                }
                message = "正在校验收件第 \(asset.ordinal)/\(candidate.assets.count) 项的全部资源"
                try await Task.detached(priority: .utility) {
                    for resource in asset.resources { try RestoreSafety.verifyResource(resource, in: directory) }
                }.value
            }
            selected = directory; manifest = candidate; manifestData = raw; requestData = requestRaw; ready = true
            let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            message = "收件大小/hash 及 PhotoKit 资源组合预检通过：\(candidate.assets.count) 项、\(resources.count) 份资源、\(size)。尚未导入；请为照片库副本和回读校验另预留约两倍资源空间。"
        } catch { message = "预检未通过：\(error.localizedDescription)" }
    }

    private func changes(_ body: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(body) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? ExportError.invalidManifest("照片库事务未成功")) }
            }
        }
    }
    private func members(_ collection: PHAssetCollection) -> (PHFetchResult<PHAsset>, [String]) {
        let fetch = PHAsset.fetchAssets(in: collection, options: nil)
        var ids: [String] = []; fetch.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return (fetch, ids)
    }
    private func verifyImported(_ asset: PHAsset, source: ExportAsset, directory: URL) async throws -> [ExportResource] {
        guard asset.pixelWidth == source.pixelWidth, asset.pixelHeight == source.pixelHeight,
              asset.mediaType.rawValue == source.mediaType,
              asset.mediaSubtypes.contains(.photoLive) == PHAssetMediaSubtype(rawValue: UInt(source.mediaSubtypes)).contains(.photoLive) else {
            throw ExportError.invalidManifest("导入后媒体类型、尺寸或 Live Photo 状态不符")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        var verified: [ExportResource] = []
        let verificationDirectory = directory.appendingPathComponent("verification")
        try FileManager.default.createDirectory(at: verificationDirectory, withIntermediateDirectories: true)
        for (index, resource) in resources.enumerated() {
            try checkPermissionAndStop()
            let path = ResourcePaths.make(ordinal: source.ordinal, resourceIndex: index + 1, originalFilename: resource.originalFilename)
            let final = directory.appendingPathComponent("verification/" + path)
            try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = final.appendingPathExtension("part")
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: part, options: options) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let receipt = try await Task.detached(priority: .utility) { try ProbeFiles.inspect(part) }.value
            try StagingFiles.commit(part: part, destination: final)
            verified.append(ExportResource(resourceIndex: index + 1, resourceType: resource.type.rawValue,
                originalFilename: resource.originalFilename, uniformTypeIdentifier: resource.uniformTypeIdentifier,
                storedRelativePath: path, sha256: receipt.sha256, byteCount: receipt.byteCount))
        }
        try JSONEncoder().encode(verified).write(to: verificationDirectory.appendingPathComponent(String(format: "%06d-resources.json", source.ordinal)), options: .withoutOverwriting)
        guard RestoreSafety.sameResources(expected: source.resources, observed: verified) else {
            throw ExportError.invalidManifest("照片库回读资源的类型、名称、UTI、长度或 SHA-256 存在差异；不能标记往返通过")
        }
        return verified
    }

    func restore(title: String) async {
        guard !busy, ready, let directory = selected, let manifest,
              let checkedManifest = manifestData, let checkedRequest = requestData else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 128 else { message = "请填写 1–128 字的新相簿名"; return }
        busy = true; ready = false; stopRequested = false; completed = 0
        defer { busy = false }
        var mapping: [String: String] = [:]; var importedIDs: [String] = []
        var verifiedModified: [String: Date] = [:]
        var albumID: String?; var claimed = false
        var log: [String: Any] = ["schemaVersion": "1.0.0", "kind": "PhotoBridgeRestoreReport",
            "manualPhotosDisplay": "NOT_RUN", "livePlayback": "NOT_RUN", "originalsDeleted": false,
            "shouldMoveFile": false, "internalMetadataWritten": false, "newAlbumTitle": name]
        func journal(_ status: String, error: String? = nil) throws {
            log["status"] = status; log["createdAssets"] = importedIDs.count
            log["mappingDirectory"] = "restore-records"
            log["resourcesVerifiedAssets"] = completed; log["createdAlbumID"] = albumID
            if let error { log["error"] = error }
            try JSONSerialization.data(withJSONObject: log, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appendingPathComponent("restore-progress.json"), options: .atomic)
        }
        do {
            try checkPermissionAndStop()
            guard try readJSONFile(directory.appendingPathComponent("album-order.json")) == checkedManifest,
                  try readJSONFile(directory.appendingPathComponent("restore-request.json")) == checkedRequest else {
                throw ExportError.invalidManifest("预检后恢复清单或 USB 请求改变，请重新预检")
            }
            // Recheck after preview: USB file sharing must not allow stale validation to import changed data.
            try await Task.detached(priority: .utility) {
                for resource in manifest.assets.flatMap(\.resources) { try RestoreSafety.verifyResource(resource, in: directory) }
            }.value
            try RestoreSafety.claimOnce(in: directory); claimed = true
            let records = directory.appendingPathComponent("restore-records")
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
            try journal("CREATING_NEW_ALBUM")
            try await changes {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                albumID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let createdID = albumID,
                  let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [createdID], options: nil).firstObject else {
                throw ExportError.invalidManifest("新相簿尚不可读取，请检查日志；不会自动重复创建")
            }
            try journal("IMPORTING")
            for source in manifest.assets {
                try checkPermissionAndStop()
                let (fetch, currentIDs) = members(collection)
                guard currentIDs == importedIDs else { throw ExportError.invalidManifest("恢复期间目标相簿成员或顺序被改变，已停止") }
                message = "正在导入第 \(source.ordinal)/\(manifest.assets.count) 项的全部资源"
                try await Task.detached(priority: .utility) {
                    for resource in source.resources { try RestoreSafety.verifyResource(resource, in: directory) }
                }.value
                log["pendingOrdinal"] = source.ordinal; try journal("IMPORTING")
                var newID: String?
                try await changes {
                    guard let albumRequest = PHAssetCollectionChangeRequest(for: collection, assets: fetch) else { return }
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = source.originalPhotoLibraryCreationDate
                    for resource in source.resources {
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = false; options.originalFilename = resource.originalFilename
                        options.uniformTypeIdentifier = resource.uniformTypeIdentifier
                        request.addResource(with: PHAssetResourceType(rawValue: resource.resourceType)!,
                            fileURL: directory.appendingPathComponent(resource.storedRelativePath), options: options)
                    }
                    if let placeholder = request.placeholderForCreatedAsset {
                        newID = placeholder.localIdentifier
                        albumRequest.insertAssets([placeholder] as NSArray, at: IndexSet(integer: source.ordinal - 1))
                    }
                }
                guard let identifier = newID else { throw ExportError.invalidManifest("导入事务没有返回资产标识，请人工检查日志，不自动重试") }
                mapping[source.sourceAssetLocalIdentifier] = identifier; importedIDs.append(identifier)
                let record: [String: Any] = ["ordinal": source.ordinal, "sourceAssetLocalIdentifier": source.sourceAssetLocalIdentifier,
                    "createdAssetLocalIdentifier": identifier, "resourceGroupId": source.resourceGroupId]
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted])
                    .write(to: records.appendingPathComponent(String(format: "%06d.json", source.ordinal)), options: .withoutOverwriting)
                try journal("VERIFYING_IMPORTED_RESOURCES")
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                    throw ExportError.invalidManifest("新资产尚不可回读，保留映射和收件文件")
                }
                _ = try await verifyImported(asset, source: source, directory: directory)
                if let date = asset.modificationDate { verifiedModified[identifier] = date }
                completed += 1; log.removeValue(forKey: "pendingOrdinal"); try journal("IMPORTING")
            }
            try checkPermissionAndStop()
            let (finalFetch, finalIDs) = members(collection)
            try RestoreSafety.verifyOrder(sourceIDs: manifest.assets.map(\.sourceAssetLocalIdentifier), mapping: mapping, observed: finalIDs)
            var changed = false
            finalFetch.enumerateObjects { asset, _, _ in
                if asset.modificationDate != verifiedModified[asset.localIdentifier] { changed = true }
            }
            guard !changed else { throw ExportError.invalidManifest("导入后资产在校验期间被编辑，不能标记完成") }
            try await Task.detached(priority: .utility) {
                for resource in manifest.assets.flatMap(\.resources) { try RestoreSafety.verifyResource(resource, in: directory) }
            }.value
            log["observedCreatedAssetIDs"] = finalIDs
            log["sourceToCreatedAssetIDs"] = mapping
            guard try readJSONFile(directory.appendingPathComponent("album-order.json")) == checkedManifest,
                  try readJSONFile(directory.appendingPathComponent("restore-request.json")) == checkedRequest else {
                throw ExportError.invalidManifest("恢复期间收件清单改变，不能标记往返通过")
            }
            try journal("PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED")
            let report = directory.appendingPathComponent("restore-report.json")
            let part = report.appendingPathExtension("part")
            try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]).write(to: part, options: .withoutOverwriting)
            try StagingFiles.commit(part: part, destination: report)
            message = "照片库回读通过：\(completed) 项的全部资源 bytes 与成员顺序一致。请在系统照片检查新相簿的自定义顺序，并逐张播放 Live Photo；人工观察尚未验证。"
        } catch {
            if claimed { try? journal("INCOMPLETE", error: error.localizedDescription) }
            message = "恢复未完成：\(error.localizedDescription)。保留已创建的新相簿、资源和日志，不删除原件，不自动重复导入。"
        }
    }
}

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 恢复 " + String(UUID().uuidString.prefix(8))
    var body: some View {
        NavigationStack {
            Form {
                Section("USB 备份收件箱") {
                    Button("刷新收件箱") { service.refresh(); session = service.sessions.last ?? "" }.disabled(service.busy)
                    if service.sessions.isEmpty { Text("没有完整收件。请在 Mac 使用 album_restore.py 发送已校验备份。") }
                    else {
                        Picker("恢复会话", selection: $session) {
                            ForEach(service.sessions, id: \.self) { value in Text(String(value.prefix(8))).tag(value) }
                        }.disabled(service.busy)
                        Button("校验收件与 PhotoKit 支持") { Task { await service.preflight(session: session) } }
                            .disabled(service.busy || session.isEmpty)
                    }
                }
                Section("创建新相簿") {
                    TextField("新相簿名", text: $title).disabled(service.busy)
                    Text("完整资源预检通过后才能写入。此操作会向照片库添加副本并创建新相簿；不修改现有相簿，不移动或删除收件文件。使用清单原拍摄日期，不把 Mac 的 5 秒辅助时间写入照片库。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("创建新相簿并导入全部资源") { Task { await service.restore(title: title) } }
                        .disabled(!service.ready || service.busy)
                    if service.busy {
                        ProgressView()
                        Button("完成当前事务后停止") { service.requestStop() }
                    }
                }
                Section("真实结果") {
                    Text(service.message).textSelection(.enabled)
                    Text("已回读校验 \(service.completed) 项").monospacedDigit()
                    Text("首版不自动续传或重放已尝试会话。中断可能留下部分新副本，请保留日志；不会通过删除或丢弃资源来掩盖差异。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("恢复")
        }.task { service.refresh(); session = service.sessions.last ?? "" }
            .onChange(of: session) { _ in service.invalidate() }
            .onDisappear { service.requestStop() }
    }
}
