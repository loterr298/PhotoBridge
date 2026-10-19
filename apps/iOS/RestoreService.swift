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
    @Published var recovering = false
    @Published var savedTitle = ""
    @Published var completed = 0
    @Published var authorizedTimestampDifferences = 0
    private var selected: URL?
    private var manifest: AlbumExportManifest?
    private var manifestData: Data?
    private var requestData: Data?
    private var allowEditTimestampRewrite = false
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
    func invalidate() { ready = false; recovering = false; savedTitle = ""; manifest = nil; selected = nil; manifestData = nil; requestData = nil; allowEditTimestampRewrite = false }
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
    func preflight(session: String, allowTimestampRewrite: Bool) async {
        guard !busy else { return }
        invalidate(); busy = true; stopRequested = false; completed = 0
        allowEditTimestampRewrite = allowTimestampRewrite; authorizedTimestampDifferences = 0
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
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-report.json").path) else {
                throw ExportError.invalidManifest("此会话已完成，不重复导入")
            }
            let hasClaim = FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-started.json").path)
            if hasClaim {
                // Legacy attempts have no immutable plan and remain permanently blocked.
                let store = try RestoreRecoveryStore(in: directory)
                let lease = try store.lock(); defer { lease.release() }
                try validate(store, manifest: candidate, raw: raw, request: requestRaw, allowed: allowTimestampRewrite)
                let state = try store.state()
                if state.albumID != nil { _ = try observed(state) }
                recovering = true; savedTitle = store.plan.title
            }
            for asset in candidate.assets {
                try checkPermissionAndStop()
                if asset.resources.contains(where: { $0.resourceType == PHAssetResourceType.adjustmentData.rawValue }) && !allowTimestampRewrite {
                    throw ExportError.invalidManifest("此备份含编辑附件。真机已发现 Photos 会重置系统编辑记录时间；严格模式停止在写入前。仅在明确允许该时间变化后开启对应选项，原始附件仍完整保留。")
                }
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
            message = (recovering ? "已有恢复记录；继续时先重新回读全部已创建副本。" : "") + "收件大小/hash 及 PhotoKit 资源组合预检通过：\(candidate.assets.count) 项、\(resources.count) 份资源、\(size)。尚未导入；请为照片库副本和回读校验另预留约两倍资源空间。"
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
    private func validate(_ store: RestoreRecoveryStore, manifest: AlbumExportManifest, raw: Data, request: Data, allowed: Bool) throws {
        try store.validateBinding(manifestSHA256: RestoreRecoveryStore.sha256(raw),
            requestSHA256: RestoreRecoveryStore.sha256(request), allowTimestampRewrite: allowed)
        guard store.plan.sourceAlbumID == manifest.sourceOrder.albumIdentifier,
              store.plan.sourceAssetIDs == manifest.assets.map(\.sourceAssetLocalIdentifier) else {
            throw ExportError.invalidManifest("恢复计划来源不符")
        }
    }
    private func observed(_ state: RestoreRecoveryState) throws -> (PHAssetCollection, PHFetchResult<PHAsset>) {
        try checkPermissionAndStop()
        guard let id = state.albumID,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ExportError.invalidManifest("已记录相簿不可见；不重建")
        }
        let (fetch, ids) = members(collection)
        let visible = PHAsset.fetchAssets(withLocalIdentifiers: state.assetIDs, options: nil)
        var visibleIDs: [String] = []; var changed = false
        visible.enumerateObjects { asset, _, _ in
            visibleIDs.append(asset.localIdentifier)
            if let version = state.verifiedVersions[asset.localIdentifier], asset.modificationDate != version { changed = true }
        }
        try state.validateObserved(albumID: collection.localIdentifier, title: collection.localizedTitle,
            memberIDs: ids, visibleAssetIDs: visibleIDs)
        guard !changed else { throw ExportError.invalidManifest("已回读副本在两次检查间被修改") }
        return (collection, fetch)
    }
    private func verifyImported(_ asset: PHAsset, source: ExportAsset, directory: URL,
                                verificationDirectory: URL, allowTimestampRewrite: Bool) async throws -> (ResourceRoundTripResult, Date) {
        guard let version = asset.modificationDate, asset.pixelWidth == source.pixelWidth, asset.pixelHeight == source.pixelHeight,
              asset.mediaType.rawValue == source.mediaType,
              asset.mediaSubtypes.contains(.photoLive) == PHAssetMediaSubtype(rawValue: UInt(source.mediaSubtypes)).contains(.photoLive) else {
            throw ExportError.invalidManifest("导入后媒体类型、尺寸、版本或 Live Photo 状态不符")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        var verified: [ExportResource] = []
        for (index, resource) in resources.enumerated() {
            try checkPermissionAndStop()
            let path = ResourcePaths.make(ordinal: source.ordinal, resourceIndex: index + 1, originalFilename: resource.originalFilename)
            let final = verificationDirectory.appendingPathComponent(path)
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
        try RestoreRecoveryStore.writeNewMetadata(JSONEncoder().encode(verified),
            to: verificationDirectory.appendingPathComponent(String(format: "%06d-resources.json", source.ordinal)))
        func boundedData(_ url: URL) throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024 * 1024 else {
                throw ExportError.invalidManifest("编辑附件不是可检查的小型普通文件")
            }
            return try Data(contentsOf: url)
        }
        let comparison = try ResourceRoundTripComparison.verify(expected: source.resources, observed: verified,
            allowAdjustmentTimestampRewrite: allowTimestampRewrite,
            loadOriginal: { try boundedData(directory.appendingPathComponent($0.storedRelativePath)) },
            loadObserved: { try boundedData(verificationDirectory.appendingPathComponent($0.storedRelativePath)) })
        guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil).firstObject,
              current.modificationDate == version else { throw ExportError.invalidManifest("副本在资源回读期间被修改") }
        try RestoreRecoveryStore.writeNewMetadata(JSONEncoder().encode(comparison),
            to: verificationDirectory.appendingPathComponent(String(format: "%06d-comparison.json", source.ordinal)))
        return (comparison, version)
    }

    func restore(title: String, stopAfterFirstCommit: Bool = false) async {
        guard !busy, ready, let directory = selected, let manifest,
              let checkedManifest = manifestData, let checkedRequest = requestData else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 128 else { message = "请填写 1–128 字的新相簿名"; return }
        let continuing = recovering
        busy = true; ready = false; stopRequested = false; completed = 0; authorizedTimestampDifferences = 0
        let userAllowedTimestampRewrite = allowEditTimestampRewrite
        defer { busy = false }
        var lease: RestoreRecoveryLease?
        defer { lease?.release() }
        var store: RestoreRecoveryStore?
        var ids: [String] = []; var albumID: String?; var newCreated = 0; var claimed = false
        var runDirectory: URL?
        var log: [String: Any] = ["schemaVersion": "1.0.0", "kind": "PhotoBridgeRestoreReport",
            "manualPhotosDisplay": "NOT_RUN", "livePlayback": "NOT_RUN", "originalsDeleted": false,
            "shouldMoveFile": false, "appInternalMediaMetadataWrites": false, "newAlbumTitle": name,
            "userAuthorizedAdjustmentTimestampRewrite": userAllowedTimestampRewrite,
            "recoveryProtocol": "explicit-placeholder-v1", "recoveryInvocation": continuing,
            "runtimeBuild": Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned",
            "runtimeVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
        func journal(_ status: String, error: String? = nil) throws {
            log["status"] = status; log["createdAssets"] = ids.count; log["newAssetsCreatedThisRun"] = newCreated
            log["mappingDirectory"] = "restore-records"; log["resourcesVerifiedAssets"] = completed; log["createdAlbumID"] = albumID
            log["authorizedAdjustmentTimestampDifferences"] = authorizedTimestampDifferences
            log["strictBytesIdenticalForVerifiedAssets"] = authorizedTimestampDifferences == 0
            if let error { log["error"] = error }
            let raw = try data(log)
            if let runDirectory { try raw.write(to: runDirectory.appendingPathComponent("progress.json"), options: .atomic) }
            try raw.write(to: directory.appendingPathComponent("restore-progress.json"), options: .atomic)
        }
        func unchangedInputs() throws {
            try checkPermissionAndStop()
            guard try readJSONFile(directory.appendingPathComponent("album-order.json")) == checkedManifest,
                  try readJSONFile(directory.appendingPathComponent("restore-request.json")) == checkedRequest else {
                throw ExportError.invalidManifest("恢复清单或 USB 请求改变")
            }
            if let store { try validate(store, manifest: manifest, raw: checkedManifest, request: checkedRequest, allowed: userAllowedTimestampRewrite) }
        }
        do {
            try unchangedInputs()
            try await Task.detached(priority: .utility) {
                for resource in manifest.assets.flatMap(\.resources) { try RestoreSafety.verifyResource(resource, in: directory) }
            }.value
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-report.json").path) else {
                throw ExportError.invalidManifest("此会话已经完成")
            }
            if continuing {
                store = try RestoreRecoveryStore(in: directory)
            } else {
                try RestoreSafety.claimOnce(in: directory); claimed = true
                let plan = RestoreRecoveryPlan(inboxSessionID: directory.lastPathComponent,
                    manifestSHA256: RestoreRecoveryStore.sha256(checkedManifest), requestSHA256: RestoreRecoveryStore.sha256(checkedRequest),
                    sourceAlbumID: manifest.sourceOrder.albumIdentifier, sourceAssetIDs: manifest.assets.map(\.sourceAssetLocalIdentifier),
                    title: name, allowTimestampRewrite: userAllowedTimestampRewrite)
                store = try RestoreRecoveryStore.create(plan: plan, in: directory)
            }
            guard let active = store else { throw ExportError.invalidManifest("缺少恢复记录") }
            lease = try active.lock(); claimed = true
            try unchangedInputs()
            guard active.plan.title == name else { throw ExportError.invalidManifest("继续时不能改变已记录的目标相簿名") }
            var state = try active.state(); ids = state.assetIDs; albumID = state.albumID
            log["recoveredExistingAssets"] = ids.count; log["attemptID"] = active.plan.attemptID
            let runID = UUID().uuidString
            let runs = directory.appendingPathComponent("restore-runs")
            let verificationRoot = directory.appendingPathComponent("verification-attempts")
            let records = directory.appendingPathComponent("restore-records")
            for root in [runs, verificationRoot, records] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try StagingResume.requireDirectory(root)
            }
            let run = runs.appendingPathComponent(runID); try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
            runDirectory = run
            let progress = directory.appendingPathComponent("restore-progress.json")
            if FileManager.default.fileExists(atPath: progress.path) {
                try RestoreRecoveryStore.writeNewMetadata(readJSONFile(progress), to: run.appendingPathComponent("previous-progress.json"))
            }
            let verification = verificationRoot.appendingPathComponent(runID)
            try FileManager.default.createDirectory(at: verification, withIntermediateDirectories: false)
            log["verificationDirectory"] = "verification-attempts/" + runID
            log["runID"] = runID
            if state.albumID == nil {
                try active.beginAlbum(); try journal("CREATING_NEW_ALBUM")
                var persistenceError: Error?
                try await changes {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                    do { try active.recordAlbumPlaceholder(request.placeholderForCreatedAssetCollection.localIdentifier) }
                    catch { persistenceError = error }
                }
                // A persistence error cannot cancel the Photos request already queued in the block.
                if let persistenceError { throw persistenceError }
                state = try active.state(); albumID = state.albumID
            }
            _ = try observed(state)
            try RestoreRecoveryStore.writeNewMetadata(data(["recordedAssetIDs": state.assetIDs, "verifiedVersionsCount": state.verifiedVersions.count]),
                to: run.appendingPathComponent("baseline.json"))
            // ponytail: full prefix validation per transaction favors safety; large-album throughput is not yet measured.
            for source in manifest.assets {
                try unchangedInputs()
                state = try active.state()
                _ = try observed(state)
                if source.ordinal > state.assetIDs.count {
                    message = "正在创建第 \(source.ordinal)/\(manifest.assets.count) 项的完整副本"
                    try await Task.detached(priority: .utility) {
                        for resource in source.resources { try RestoreSafety.verifyResource(resource, in: directory) }
                    }.value
                    try unchangedInputs()
                    let (collection, fetch) = try observed(try active.state())
                    try active.beginAsset(ordinal: source.ordinal)
                    log["pendingOrdinal"] = source.ordinal; try journal("IMPORTING")
                    var persistenceError: Error?; var creationRequested = false
                    try await changes {
                        guard let albumRequest = PHAssetCollectionChangeRequest(for: collection, assets: fetch) else { return }
                        let request = PHAssetCreationRequest.forAsset(); creationRequested = true
                        request.creationDate = source.originalPhotoLibraryCreationDate
                        for resource in source.resources {
                            let options = PHAssetResourceCreationOptions()
                            options.shouldMoveFile = false; options.originalFilename = resource.originalFilename
                            options.uniformTypeIdentifier = resource.uniformTypeIdentifier
                            request.addResource(with: PHAssetResourceType(rawValue: resource.resourceType)!,
                                fileURL: directory.appendingPathComponent(resource.storedRelativePath), options: options)
                        }
                        if let placeholder = request.placeholderForCreatedAsset {
                            do { try active.recordAssetPlaceholder(ordinal: source.ordinal, identifier: placeholder.localIdentifier) }
                            catch { persistenceError = error }
                            albumRequest.insertAssets([placeholder] as NSArray, at: IndexSet(integer: source.ordinal - 1))
                        }
                    }
                    if let persistenceError { throw persistenceError }
                    guard creationRequested else { throw ExportError.invalidManifest("未取得相簿写入请求；保留意图，不重试创建") }
                    state = try active.state(); ids = state.assetIDs
                    guard ids.count == source.ordinal else { throw ExportError.invalidManifest("创建事务缺少持久化标识") }
                    _ = try observed(state); newCreated += 1
                    if stopAfterFirstCommit && !continuing && newCreated == 1 {
                        log["diagnosticStopWindow"] = "AFTER_FIRST_PHOTOS_COMMIT_BEFORE_RESOURCE_VERIFICATION"
                        throw ExportError.invalidManifest("诊断已停止：1 个副本已提交且标识已保存，资源尚未回读。重启后重新预检此会话再继续")
                    }
                }
                ids = state.assetIDs
                let identifier = ids[source.ordinal - 1]
                let record: [String: Any] = ["ordinal": source.ordinal, "sourceAssetLocalIdentifier": source.sourceAssetLocalIdentifier,
                    "createdAssetLocalIdentifier": identifier, "resourceGroupId": source.resourceGroupId]
                let recordURL = records.appendingPathComponent(String(format: "%06d.json", source.ordinal))
                let recordData = try data(record)
                if FileManager.default.fileExists(atPath: recordURL.path) {
                    guard try readJSONFile(recordURL) == recordData else { throw ExportError.invalidManifest("既有副本映射改变") }
                } else { try RestoreRecoveryStore.writeNewMetadata(recordData, to: recordURL) }
                try journal("VERIFYING_IMPORTED_RESOURCES")
                message = "正在重新回读第 \(source.ordinal)/\(manifest.assets.count) 项的全部资源"
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                    throw ExportError.invalidManifest("已记录副本不可见，不重试创建")
                }
                let (comparison, version) = try await verifyImported(asset, source: source, directory: directory,
                    verificationDirectory: verification, allowTimestampRewrite: userAllowedTimestampRewrite)
                try active.recordVerified(ordinal: source.ordinal, identifier: identifier, modified: version)
                authorizedTimestampDifferences += comparison.authorizedAdjustmentTimestampDifferences
                completed += 1; log.removeValue(forKey: "pendingOrdinal"); try journal("IMPORTING")
            }
            try unchangedInputs()
            state = try active.state(); ids = state.assetIDs
            let (_, finalFetch) = try observed(state)
            guard state.verifiedVersions.count == manifest.assets.count else { throw ExportError.invalidManifest("回读记录不完整") }
            var finalIDs: [String] = []; finalFetch.enumerateObjects { asset, _, _ in finalIDs.append(asset.localIdentifier) }
            var mapping: [String: String] = [:]
            for (source, id) in zip(manifest.assets, ids) { mapping[source.sourceAssetLocalIdentifier] = id }
            try RestoreSafety.verifyOrder(sourceIDs: manifest.assets.map(\.sourceAssetLocalIdentifier), mapping: mapping, observed: finalIDs)
            try await Task.detached(priority: .utility) {
                for resource in manifest.assets.flatMap(\.resources) { try RestoreSafety.verifyResource(resource, in: directory) }
            }.value
            try unchangedInputs(); _ = try observed(try active.state())
            log["observedCreatedAssetIDs"] = finalIDs; log["sourceToCreatedAssetIDs"] = mapping
            let status = authorizedTimestampDifferences == 0 ? "PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED" : "PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS"
            try journal(status)
            try RestoreRecoveryStore.writeNewMetadata(data(log), to: directory.appendingPathComponent("restore-report.json"))
            message = "照片库回读完成：\(completed) 项，本次新建 \(newCreated) 项，复用已有 \(log["recoveredExistingAssets"] ?? 0) 项。成员顺序通过；\(authorizedTimestampDifferences) 份附件仅已授权的编辑时间变化。请在系统照片独立核对自定义顺序、编辑效果及 Live Photo 播放；人工观察尚未验证。"
        } catch {
            if claimed { try? journal("INCOMPLETE", error: error.localizedDescription) }
            message = "恢复未完成：\(error.localizedDescription)。保留新副本、原件和全部日志；仅有完整持久化标识且实际回读一致的新版会话可在重新预检后继续，状态不明确时拒绝重放。"
        }
    }
}
