import SwiftUI
import Photos
import PhotoBridgeCore

struct RestorePreviewItem: Identifiable, Equatable, Sendable {
    let id: String
    let ordinal: Int
    let filename: String
    let url: URL
}

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
    @Published var sessionLabels: [String: String] = [:]
    @Published var previewItems: [RestorePreviewItem] = []
    @Published var loadingPreview = false
    @Published var loadingSessions = false
    @Published var busy = false { didSet { PhoneActivity.shared.set("import", active: busy) } }
    @Published var ready = false
    @Published var message = ""
    @Published var preflightReportSummary = ""
    @Published var sharedPreflightReport = false
    private var privatePreflightReport: URL?
    @Published var recovering = false
    @Published var savedTitle = ""
    @Published var completed = 0
    @Published var checked = 0
    @Published var phase = "IDLE"
    @Published var verifiedFinished = false
    var displayProgress: PhotoProgress { PhotoProgress(completed: phase == "CHECKING" ? checked : completed, total: totalAssets, finished: verifiedFinished || (ready && phase == "CHECKING")) }
    @Published var totalAssets = 0
    @Published var authorizedTimestampDifferences = 0
    private var selected: URL?
    private var manifest: AlbumExportManifest?
    private var manifestData: Data?
    private var requestData: Data?
    private var allowEditTimestampRewrite = false
    private var stopRequested = false
    private var cancellation = OperationCancellation()
    private var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RestoreInbox")
    }

    func refresh() async {
        guard !busy && !loadingSessions else { return }
        invalidate(); message = ""; loadingSessions = true
        defer { loadingSessions = false }
        let folder = inbox
        do {
            let entries = try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try StagingResume.requireDirectory(folder)
                var values: [(String, String, Date)] = []
                for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where UUID(uuidString: name) != nil {
                    try Task.checkCancellation()
                    let session = folder.appendingPathComponent(name)
                    guard (try? StagingResume.requireDirectory(session)) != nil,
                          !FileManager.default.fileExists(atPath: session.appendingPathComponent("restore-report.json").path) else { continue }
                    let file = session.appendingPathComponent("restore-request.json")
                    guard let a = try? FileManager.default.attributesOfItem(atPath: file.path), a[.type] as? FileAttributeType == .typeRegular,
                          let size = a[.size] as? NSNumber, size.intValue <= 65_536,
                          let data = try? Data(contentsOf: file),
                          let request = try? JSONDecoder().decode(RestoreInboxRequest.self, from: data), request.sessionID == name, request.state == "USB_VERIFIED" else { continue }
                    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    let album = String((object?["albumName"] as? String ?? "收到的相册").prefix(128))
                    let date = (a[.modificationDate] as? Date) ?? .distantPast
                    values.append((name, "\(album) · \(request.assetCount.formatted()) 张 · \(date.formatted(date: .abbreviated, time: .shortened))", date))
                }
                return values.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }
            }.value
            sessions = entries.map { $0.0 }; sessionLabels = Dictionary(uniqueKeysWithValues: entries.map { ($0.0, $0.1) })
        } catch { message = "暂时无法读取收到的照片，请重新查找。" }
    }
    func invalidate() { guard !busy else { return }; verifiedFinished = false; completed = 0; checked = 0; totalAssets = 0; phase = "IDLE"; preflightReportSummary = ""; sharedPreflightReport = false; privatePreflightReport = nil; ready = false; recovering = false; savedTitle = ""; manifest = nil; selected = nil; manifestData = nil; requestData = nil; allowEditTimestampRewrite = false; previewItems = []; loadingPreview = false }
    func loadPreview(session: String) async {
        guard UUID(uuidString: session) != nil else { previewItems = []; return }
        loadingPreview = true
        let folder = inbox.appendingPathComponent(session, isDirectory: true)
        let values = await Task.detached(priority: .utility) { Self.previewItems(in: folder) }.value
        guard !Task.isCancelled else { return }
        previewItems = values
        loadingPreview = false
    }
    nonisolated private static func previewItems(in folder: URL) -> [RestorePreviewItem] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("album-order.json")),
              let manifest = try? JSONDecoder().decode(AlbumExportManifest.self, from: data) else { return [] }
        return manifest.assets.compactMap { asset in
            let resource = asset.resources.first { item in
                let path = folder.appendingPathComponent(item.storedRelativePath)
                let ext = path.pathExtension.lowercased()
                return FileManager.default.fileExists(atPath: path.path) && ["jpg", "jpeg", "heic", "png", "dng", "tif", "tiff"].contains(ext)
            } ?? asset.resources.first { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.storedRelativePath).path) }
            guard let resource else { return nil }
            let url = folder.appendingPathComponent(resource.storedRelativePath)
            return RestorePreviewItem(id: "\(asset.ordinal)-\(resource.resourceIndex)", ordinal: asset.ordinal,
                                      filename: resource.originalFilename, url: url)
        }
    }
    func requestStop() { stopRequested = true; cancellation.cancel() }
    private func checkPermissionAndStop() throws {
        guard !stopRequested && !Task.isCancelled else { throw ExportError.invalidManifest("已在事务边界停止；不会自动重复导入") }
        try PhotoOperationChecks.requireFullAccess()
    }
    nonisolated private func readJSONFile(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
            throw ExportError.invalidManifest("无效或过大的恢复清单")
        }
        return try Data(contentsOf: url)
    }
    nonisolated private func readInbox(_ directory: URL, session: String, cancellation: OperationCancellation) throws
        -> (raw: Data, request: Data, manifest: AlbumExportManifest, resources: Int, bytes: Int, digest: String) {
        try cancellation.check()
        let requestRaw = try readJSONFile(directory.appendingPathComponent("restore-request.json"))
        let request = try JSONDecoder().decode(RestoreInboxRequest.self, from: requestRaw)
        let raw = try readJSONFile(directory.appendingPathComponent("album-order.json"))
        let candidate = try RestoreSafety.decodeManifest(data: raw, expectedSHA256: request.sourceManifestSHA256)
        var resources = 0; var totalBytes = 0
        for asset in candidate.assets {
            try cancellation.check()
            resources += asset.resources.count
            for resource in asset.resources {
                let (sum, overflow) = totalBytes.addingReportingOverflow(resource.byteCount)
                guard !overflow else { throw ExportError.invalidManifest("资源总大小超出支持范围") }
                totalBytes = sum
            }
        }
        guard request.schemaVersion == "1.0.0", request.kind == "PhotoBridgeRestoreRequest",
              request.sessionID == session, request.state == "USB_VERIFIED",
              request.assetCount == candidate.assets.count, request.resourceCount == resources,
              request.byteCount == totalBytes else { throw ExportError.invalidManifest("USB 收件标记或资源数量/hash 不一致") }
        try cancellation.check()
        return (raw, requestRaw, candidate, resources, totalBytes, request.sourceManifestSHA256)
    }
    func preflight(session: String, allowTimestampRewrite: Bool, simulateNoSpace: Bool = false) async {
        guard !busy else { return }
        invalidate(); busy = true; stopRequested = false; completed = 0; totalAssets = 0; checked = 0; phase = "CHECKING"; verifiedFinished = false
        let cancellation = OperationCancellation(); self.cancellation = cancellation
        message = "正在读取照片清单…"
        allowEditTimestampRewrite = allowTimestampRewrite; authorizedTimestampDifferences = 0
        var preflightReport: [String: Any] = ["kind": "PhotoBridgePreflightReport", "schemaVersion": "1.0.0",
            "sessionID": session, "simulatedZeroCapacity": simulateNoSpace,
            "photoAccessAtStart": PhotoOperationChecks.access.rawValue,
            "photoKitCreationRequestsIssuedByPreflight": false, "resourcesHashVerified": 0,
            "runtimeBuild": Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned",
            "runtimeVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        defer {
            preflightReport["status"] = ready ? "READY" : "BLOCKED"
            preflightReport["photoAccessAtEnd"] = PhotoOperationChecks.access.rawValue
            do {
                let logs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RestoreChecksPrivate")
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                try StagingResume.requireDirectory(logs)
                let report = logs.appendingPathComponent(UUID().uuidString + ".json")
                try RestoreRecoveryStore.writeNewMetadata(JSONSerialization.data(withJSONObject: preflightReport, options: [.sortedKeys, .prettyPrinted]), to: report)
                privatePreflightReport = report
                let actual = preflightReport["actualAvailableBytes"] as? Int64
                let required = preflightReport["requiredEstimatedBytes"] as? Int64
                preflightReportSummary = "本次诊断：\(preflightReport["status"] ?? "unknown")；照片权限 \(preflightReport["photoAccessAtStart"] ?? "unknown")。" +
                    (actual.map { "实际可用 \($0) bytes；" } ?? "本次未取得容量值；") +
                    (required.map { "估算另需 \($0) bytes；" } ?? "尚未计算空间需求；") +
                    "模拟零空间：\(simulateNoSpace ? "是" : "否")。报告还含会话标识、来源清单 hash、资源计数和运行版本；仅用于本次故障诊断。"
            } catch { ready = false; message += "。诊断日志未能保存：\(error.localizedDescription)" }
            busy = false
        }
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
            let checked = try await Task.detached(priority: .utility) {
                try autoreleasepool { try self.readInbox(directory, session: session, cancellation: cancellation) }
            }.value
            try checkPermissionAndStop()
            let raw = checked.raw; let requestRaw = checked.request; let candidate = checked.manifest
            let totalBytes = checked.bytes
            totalAssets = candidate.assets.count
            preflightReport["manifestSHA256"] = checked.digest
            preflightReport["assets"] = candidate.assets.count; preflightReport["resources"] = checked.resources
            var recordedAssets = 0
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-report.json").path) else {
                throw ExportError.invalidManifest("此会话已完成，不重复导入")
            }
            let hasClaim = FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-started.json").path)
            if hasClaim {
                // Legacy attempts have no immutable plan and remain permanently blocked.
                let store = try await Task.detached(priority: .utility) { try RestoreRecoveryStore(in: directory) }.value
                let lease = try await Task.detached(priority: .utility) { try store.lock() }.value; defer { lease.release() }
                let state = try await Task.detached(priority: .utility) {
                    try self.validate(store, manifest: candidate, raw: raw, request: requestRaw, allowed: allowTimestampRewrite)
                    return try store.state(checkCancellation: cancellation.check)
                }.value
                if state.albumID != nil { _ = try await observed(state) }
                recovering = true; savedTitle = store.plan.title; recordedAssets = state.assetIDs.count
            }
            let budget = try RestoreWriteBudget(resourceBytesByAsset: candidate.assets.map { $0.resources.map { Int64($0.byteCount) } },
                recordedAssets: recordedAssets, verifiedThisRun: 0)
            let actualCapacity = try PhotoOperationChecks.availableCapacity(at: directory)
            preflightReport["actualAvailableBytes"] = actualCapacity.map { $0 as Any } ?? NSNull()
            preflightReport["effectiveAvailableBytes"] = simulateNoSpace ? 0 : (actualCapacity.map { $0 as Any } ?? NSNull())
            preflightReport["requiredEstimatedBytes"] = budget.requiredBytes
            preflightReport["remainingPhotoCopyBytes"] = budget.remainingPhotoCopyBytes
            preflightReport["remainingReadbackBytes"] = budget.remainingReadbackBytes
            preflightReport["reserveBytes"] = budget.reserveBytes; preflightReport["recordedAssets"] = recordedAssets
            try OperationPreconditions.requireCapacity(simulateNoSpace ? 0 : actualCapacity, budget: budget)
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
                message = "正在检查第 \(asset.ordinal)/\(candidate.assets.count) 张照片"
                try await Task.detached(priority: .utility) {
                    for resource in asset.resources { try RestoreSafety.verifyResource(resource, in: directory, checkCancellation: cancellation.check) }
                }.value
                preflightReport["resourcesHashVerified"] = (preflightReport["resourcesHashVerified"] as? Int ?? 0) + asset.resources.count
                self.checked = asset.ordinal
            }
            try checkPermissionAndStop()
            selected = directory; manifest = candidate; manifestData = raw; requestData = requestRaw; ready = true
            let size = ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
            message = (recovering ? "已找到 \(recordedAssets) 张已恢复照片，继续前会再次检查。" : "准备恢复。") + "共 \(candidate.assets.count) 张照片，占用约 \(size)。"
        } catch {
            ready = false
            preflightReport["failureCode"] = (error as? OperationPreconditionFailure)?.code ?? "PREFLIGHT_FAILED"
            preflightReport["error"] = error.localizedDescription
            message = error is CancellationError || stopRequested ? "已暂停检查，原照片不受影响。" : (simulateNoSpace ? "空间不足测试：" : "检查未通过：") + "\(error.localizedDescription)"
        }
    }

    func sharePreflightReportWithMac() {
        guard !busy, !sharedPreflightReport, let report = privatePreflightReport else { return }
        do {
            let logs = inbox.deletingLastPathComponent().appendingPathComponent("RestoreChecks")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try StagingResume.requireDirectory(logs)
            try RestoreRecoveryStore.writeNewMetadata(readJSONFile(report), to: logs.appendingPathComponent(report.lastPathComponent))
            sharedPreflightReport = true
        } catch { message += "。报告共享未完成：\(error.localizedDescription)" }
    }

    private func changes(_ body: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(body) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? ExportError.invalidManifest("照片库事务未成功")) }
            }
        }
    }
    nonisolated private func validate(_ store: RestoreRecoveryStore, manifest: AlbumExportManifest, raw: Data, request: Data, allowed: Bool) throws {
        try store.validateBinding(manifestSHA256: RestoreRecoveryStore.sha256(raw),
            requestSHA256: RestoreRecoveryStore.sha256(request), allowTimestampRewrite: allowed)
        guard store.plan.sourceAlbumID == manifest.sourceOrder.albumIdentifier,
              store.plan.sourceAssetIDs == manifest.assets.map(\.sourceAssetLocalIdentifier) else {
            throw ExportError.invalidManifest("恢复计划来源不符")
        }
    }
    private func observed(_ state: RestoreRecoveryState) async throws -> (PHAssetCollection, PHFetchResult<PHAsset>, [String]) {
        try checkPermissionAndStop()
        let cancellation = self.cancellation
        let result = try await Task.detached(priority: .utility) { try autoreleasepool { try Self.observe(state, cancellation: cancellation) } }.value
        try checkPermissionAndStop()
        return result
    }
    nonisolated private static func observe(_ state: RestoreRecoveryState, cancellation: OperationCancellation) throws
        -> (PHAssetCollection, PHFetchResult<PHAsset>, [String]) {
        try PhotoOperationChecks.requireFullAccess(); try cancellation.check()
        guard let id = state.albumID,
              let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ExportError.invalidManifest("已记录相簿不可见；不重建")
        }
        let fetch = PHAsset.fetchAssets(in: collection, options: nil)
        var ids: [String] = []
        for index in 0..<fetch.count {
            try cancellation.check()
            autoreleasepool { ids.append(fetch.object(at: index).localIdentifier) }
        }
        let visible = PHAsset.fetchAssets(withLocalIdentifiers: state.assetIDs, options: nil)
        var visibleIDs: [String] = []; var changed = false
        for index in 0..<visible.count {
            try cancellation.check()
            let asset = visible.object(at: index)
            visibleIDs.append(asset.localIdentifier)
            if let version = state.verifiedVersions[asset.localIdentifier], asset.modificationDate != version { changed = true }
        }
        try state.validateObserved(albumID: collection.localIdentifier, title: collection.localizedTitle,
            memberIDs: ids, visibleAssetIDs: visibleIDs)
        guard !changed else { throw ExportError.invalidManifest("已回读副本在两次检查间被修改") }
        try cancellation.check(); try PhotoOperationChecks.requireFullAccess()
        return (collection, fetch, ids)
    }
    private func verifyImported(_ asset: PHAsset, source: ExportAsset, directory: URL,
                                verificationDirectory: URL, allowTimestampRewrite: Bool, checkReadbackSpace: (Int64) throws -> Void) async throws -> (ResourceRoundTripResult, Date) {
        guard let version = asset.modificationDate, asset.pixelWidth == source.pixelWidth, asset.pixelHeight == source.pixelHeight,
              asset.mediaType.rawValue == source.mediaType,
              asset.mediaSubtypes.contains(.photoLive) == PHAssetMediaSubtype(rawValue: UInt(source.mediaSubtypes)).contains(.photoLive) else {
            throw ExportError.invalidManifest("导入后媒体类型、尺寸、版本或 Live Photo 状态不符")
        }
        try RestoreSafety.verifyCreationDate(expected: source.originalPhotoLibraryCreationDate, observed: asset.creationDate)
        let resources = PHAssetResource.assetResources(for: asset)
        var verified: [ExportResource] = []
        var committedReadbackBytes: Int64 = 0
        for (index, resource) in resources.enumerated() {
            try checkPermissionAndStop()
            try checkReadbackSpace(committedReadbackBytes)
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
            let cancellation = self.cancellation
            let receipt = try await Task.detached(priority: .utility) { try ProbeFiles.inspect(part, checkCancellation: cancellation.check) }.value
            try StagingFiles.commit(part: part, destination: final)
            let (sum, overflow) = committedReadbackBytes.addingReportingOverflow(Int64(receipt.byteCount))
            guard !overflow else { throw OperationPreconditionFailure.invalidBudget }
            committedReadbackBytes = sum
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
        try RestoreSafety.verifyCreationDate(expected: source.originalPhotoLibraryCreationDate, observed: current.creationDate)
        try RestoreRecoveryStore.writeNewMetadata(JSONEncoder().encode(comparison),
            to: verificationDirectory.appendingPathComponent(String(format: "%06d-comparison.json", source.ordinal)))
        return (comparison, version)
    }

    func restore(title: String, stopAfterFirstCommit: Bool = false) async {
        guard !busy, ready, let directory = selected, let manifest,
              let checkedManifest = manifestData, let checkedRequest = requestData else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty && name.count <= 128 else { message = "请输入 1–128 个字符的相册名称"; return }
        let continuing = recovering
        busy = true; ready = false; stopRequested = false; completed = 0; phase = "IMPORTING"; verifiedFinished = false; totalAssets = manifest.assets.count; authorizedTimestampDifferences = 0
        let cancellation = OperationCancellation(); self.cancellation = cancellation
        message = "正在检查照片，原照片会保留…"
        let userAllowedTimestampRewrite = allowEditTimestampRewrite
        defer { busy = false }
        var lease: RestoreRecoveryLease?
        defer { lease?.release() }
        var store: RestoreRecoveryStore?
        var ids: [String] = []; var albumID: String?; var newCreated = 0; var claimed = false
        let operationID = UUID().uuidString
        var runDirectory: URL?
        var log: [String: Any] = ["schemaVersion": "1.0.0", "kind": "PhotoBridgeRestoreReport",
            "manualPhotosDisplay": "NOT_RUN", "livePlayback": "NOT_RUN", "originalsDeleted": false,
            "shouldMoveFile": false, "appInternalMediaMetadataWrites": false, "newAlbumTitle": name,
            "userAuthorizedAdjustmentTimestampRewrite": userAllowedTimestampRewrite,
            "recoveryProtocol": "explicit-placeholder-v1", "recoveryInvocation": continuing,
            "runtimeBuild": Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned",
            "runtimeVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
        func journal(_ status: String, error: String? = nil) async throws {
            log["status"] = status; log["createdAssets"] = ids.count; log["newAssetsCreatedThisRun"] = newCreated
            log["mappingDirectory"] = "restore-records"; log["resourcesVerifiedAssets"] = completed; log["createdAlbumID"] = albumID
            log["authorizedAdjustmentTimestampDifferences"] = authorizedTimestampDifferences
            log["strictBytesIdenticalForVerifiedAssets"] = authorizedTimestampDifferences == 0
            if let error { log["error"] = error }
            let frozen = log; let run = runDirectory
            let display = TransferDisplay(operationID: operationID, direction: "IMPORT", phase: status,
                completed: completed, total: totalAssets, sessionID: directory.lastPathComponent)
            let control = inbox.deletingLastPathComponent().appendingPathComponent("Control")
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    let raw = try JSONSerialization.data(withJSONObject: frozen, options: [.sortedKeys, .prettyPrinted])
                    if let run { try raw.write(to: run.appendingPathComponent("progress.json"), options: .atomic) }
                    try raw.write(to: directory.appendingPathComponent("restore-progress.json"), options: .atomic)
                    // Advisory progress must not turn a committed Photos write into a failed transaction.
                    if FileManager.default.fileExists(atPath: control.path) {
                        try? JSONEncoder().encode(display).write(to: control.appendingPathComponent("restore-progress.json"), options: .atomic)
                    }
                }
            }.value
        }
        let sizes = manifest.assets.map { $0.resources.map { Int64($0.byteCount) } }
        var budgetPlan: RestoreBudgetPlan?
        func checkSpace(recorded: Int, verified: Int, currentReadbackBytes: Int64 = 0) throws {
            try checkPermissionAndStop()
            guard let budgetPlan else { throw OperationPreconditionFailure.invalidBudget }
            let budget = try budgetPlan.budget(recordedAssets: recorded, verifiedThisRun: verified, committedResourceBytesInCurrentAsset: currentReadbackBytes)
            let available = try PhotoOperationChecks.availableCapacity(at: directory)
            log["latestCapacityCheck"] = ["requiredEstimatedBytes": budget.requiredBytes,
                "reserveBytes": budget.reserveBytes,
                "remainingPhotoCopyBytes": budget.remainingPhotoCopyBytes, "remainingReadbackBytes": budget.remainingReadbackBytes]
            try OperationPreconditions.requireCapacity(available, budget: budget)
        }
        func replay(_ active: RestoreRecoveryStore) async throws -> RestoreRecoveryState {
            try await Task.detached(priority: .utility) { try autoreleasepool { try active.state(checkCancellation: cancellation.check) } }.value
        }
        func unchangedInputs() async throws {
            try checkPermissionAndStop()
            let active = store
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                try cancellation.check()
                guard try self.readJSONFile(directory.appendingPathComponent("album-order.json")) == checkedManifest,
                      try self.readJSONFile(directory.appendingPathComponent("restore-request.json")) == checkedRequest else {
                    throw ExportError.invalidManifest("恢复清单或 USB 请求改变")
                }
                if let active { try self.validate(active, manifest: manifest, raw: checkedManifest, request: checkedRequest, allowed: userAllowedTimestampRewrite) }
                try cancellation.check()
                }
            }.value
            try checkPermissionAndStop()
        }
        do {
            budgetPlan = try RestoreBudgetPlan(resourceBytesByAsset: sizes)
            try await unchangedInputs()
            try await Task.detached(priority: .utility) {
                for asset in manifest.assets { for resource in asset.resources { try RestoreSafety.verifyResource(resource, in: directory, checkCancellation: cancellation.check) } }
            }.value
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore-report.json").path) else {
                throw ExportError.invalidManifest("此会话已经完成")
            }
            let recordedBeforeClaim = continuing ? try await Task.detached(priority: .utility) { try RestoreRecoveryStore(in: directory).state(checkCancellation: cancellation.check).assetIDs.count }.value : 0
            try checkSpace(recorded: recordedBeforeClaim, verified: 0)
            if continuing {
                store = try await Task.detached(priority: .utility) { try RestoreRecoveryStore(in: directory) }.value
            } else {
                try RestoreSafety.claimOnce(in: directory); claimed = true
                let plan = RestoreRecoveryPlan(inboxSessionID: directory.lastPathComponent,
                    manifestSHA256: RestoreRecoveryStore.sha256(checkedManifest), requestSHA256: RestoreRecoveryStore.sha256(checkedRequest),
                    sourceAlbumID: manifest.sourceOrder.albumIdentifier, sourceAssetIDs: manifest.assets.map(\.sourceAssetLocalIdentifier),
                    title: name, allowTimestampRewrite: userAllowedTimestampRewrite)
                store = try await Task.detached(priority: .utility) { try RestoreRecoveryStore.create(plan: plan, in: directory) }.value
            }
            guard let active = store else { throw ExportError.invalidManifest("缺少恢复记录") }
            lease = try await Task.detached(priority: .utility) { try active.lock() }.value; claimed = true
            try await unchangedInputs()
            guard active.plan.title == name else { throw ExportError.invalidManifest("继续时不能改变已记录的目标相簿名") }
            var state = try await replay(active); ids = state.assetIDs; albumID = state.albumID
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
                try checkSpace(recorded: 0, verified: 0)
                try await Task.detached(priority: .utility) { try active.beginAlbum(checkCancellation: cancellation.check) }.value; try await journal("CREATING_NEW_ALBUM")
                var persistenceError: Error?
                try await changes {
                    let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                    do { try active.recordAlbumPlaceholder(request.placeholderForCreatedAssetCollection.localIdentifier) }
                    catch { persistenceError = error }
                }
                // A persistence error cannot cancel the Photos request already queued in the block.
                if let persistenceError { throw persistenceError }
                state = try await replay(active); albumID = state.albumID
            }
            _ = try await observed(state)
            let baselineIDs = state.assetIDs; let baselineVersions = state.verifiedVersions.count
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    let raw = try JSONSerialization.data(withJSONObject: ["recordedAssetIDs": baselineIDs, "verifiedVersionsCount": baselineVersions], options: [.sortedKeys])
                    try RestoreRecoveryStore.writeNewMetadata(raw, to: run.appendingPathComponent("baseline.json"))
                }
            }.value
            // ponytail: full prefix validation per transaction favors safety; large-album throughput is not yet measured.
            for source in manifest.assets {
                try await unchangedInputs()
                state = try await replay(active)
                _ = try await observed(state)
                if source.ordinal > state.assetIDs.count {
                    message = "正在恢复第 \(source.ordinal)/\(manifest.assets.count) 张照片"
                    try await Task.detached(priority: .utility) {
                        for resource in source.resources { try RestoreSafety.verifyResource(resource, in: directory, checkCancellation: cancellation.check) }
                    }.value
                    try await unchangedInputs()
                    let (collection, fetch, _) = try await observed(try await replay(active))
                    try checkSpace(recorded: state.assetIDs.count, verified: completed)
                    try await Task.detached(priority: .utility) { try active.beginAsset(ordinal: source.ordinal, checkCancellation: cancellation.check) }.value
                    log["pendingOrdinal"] = source.ordinal; try await journal("IMPORTING")
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
                    state = try await replay(active); ids = state.assetIDs
                    guard ids.count == source.ordinal else { throw ExportError.invalidManifest("创建事务缺少持久化标识") }
                    _ = try await observed(state); newCreated += 1
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
                try checkSpace(recorded: state.assetIDs.count, verified: completed)
                try await journal("VERIFYING_IMPORTED_RESOURCES")
                message = "正在检查第 \(source.ordinal)/\(manifest.assets.count) 张照片"
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                    throw ExportError.invalidManifest("已记录副本不可见，不重试创建")
                }
                let (comparison, version) = try await verifyImported(asset, source: source, directory: directory,
                    verificationDirectory: verification, allowTimestampRewrite: userAllowedTimestampRewrite,
                    checkReadbackSpace: { bytes in try checkSpace(recorded: state.assetIDs.count, verified: completed, currentReadbackBytes: bytes) })
                try await Task.detached(priority: .utility) { try active.recordVerified(ordinal: source.ordinal, identifier: identifier, modified: version) }.value
                authorizedTimestampDifferences += comparison.authorizedAdjustmentTimestampDifferences
                completed += 1; log.removeValue(forKey: "pendingOrdinal"); try await journal("IMPORTING")
            }
            try await unchangedInputs()
            phase = "FINALIZING"
            state = try await replay(active); ids = state.assetIDs
            let (_, _, finalIDs) = try await observed(state)
            guard state.verifiedVersions.count == manifest.assets.count else { throw ExportError.invalidManifest("回读记录不完整") }
            var mapping: [String: String] = [:]
            for (source, id) in zip(manifest.assets, ids) { mapping[source.sourceAssetLocalIdentifier] = id }
            try RestoreSafety.verifyOrder(sourceIDs: manifest.assets.map(\.sourceAssetLocalIdentifier), mapping: mapping, observed: finalIDs)
            try await Task.detached(priority: .utility) {
                for asset in manifest.assets { for resource in asset.resources { try RestoreSafety.verifyResource(resource, in: directory, checkCancellation: cancellation.check) } }
            }.value
            try await unchangedInputs(); _ = try await observed(try await replay(active))
            log["observedCreatedAssetIDs"] = finalIDs; log["sourceToCreatedAssetIDs"] = mapping
            let status = authorizedTimestampDifferences == 0 ? "PHOTO_LIBRARY_BYTES_AND_ORDER_VERIFIED" : "PHOTO_LIBRARY_NON_TIME_DATA_AND_ORDER_VERIFIED_WITH_AUTHORIZED_EDIT_TIMESTAMPS"
            try checkPermissionAndStop()
            var finalLog = log
            finalLog["status"] = status
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    let raw = try JSONSerialization.data(withJSONObject: finalLog, options: [.sortedKeys, .prettyPrinted])
                    try RestoreRecoveryStore.writeNewMetadata(raw, to: directory.appendingPathComponent("restore-report.json"))
                }
            }.value
            // The durable report is the completion authority. A disposable progress
            // publication failure cannot reverse a verified Photos transaction.
            try? await journal(status)
            verifiedFinished = true
            message = "恢复完成：\(completed) 张照片已添加到新相册。请在照片中确认顺序、编辑效果和动态照片播放。"
        } catch {
            log["failureCode"] = (error as? OperationPreconditionFailure)?.code ?? "RESTORE_INCOMPLETE"
            if claimed { try? await journal("INCOMPLETE", error: (error as? OperationPreconditionFailure)?.code ?? error.localizedDescription) }
            message = error is CancellationError || stopRequested ? "已暂停。已完成的照片和原照片都已保留，检查通过后可以继续。" : "恢复未完成：\(error.localizedDescription)。已完成的照片和原照片都已保留，检查通过后可以继续。"
        }
    }
}
