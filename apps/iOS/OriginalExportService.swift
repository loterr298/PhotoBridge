import SwiftUI
import Photos
import PhotoBridgeCore

struct StagingCandidate: Identifiable {
    let id: String
    let capturedAt: Date
}

@MainActor final class OriginalExportService: ObservableObject {
    @Published var busy = false
    @Published var message = "尚未导出"
    @Published var resourcesCompleted = 0
    @Published var totalResources = 0
    @Published var bytesCompleted = 0
    @Published var reusedResources = 0
    @Published var photoKitResourcesRead = 0
    @Published var sessionName: String?
    @Published var candidates: [StagingCandidate] = []
    private var stopRequested = false
    private var exports: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
    }
    func requestStop() { stopRequested = true }
    private static func source(_ asset: PHAsset, resources: [PHAssetResource]) -> StagingAssetSource {
        StagingAssetSource(identifier: asset.localIdentifier, modificationDate: asset.modificationDate,
            creationDate: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            mediaType: asset.mediaType.rawValue, mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue),
            resources: resources.map { StagingResourceSource(resourceType: $0.type.rawValue,
                originalFilename: $0.originalFilename, uniformTypeIdentifier: $0.uniformTypeIdentifier) })
    }
    private func capture(_ collection: PHAssetCollection) throws -> (name: String, assets: [StagingAssetSource]) {
        try checkPermission()
        guard let current = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collection.localIdentifier], options: nil).firstObject else {
            throw ExportError.invalidManifest("来源相簿已不可访问")
        }
        let result = PHAsset.fetchAssets(in: current, options: nil)
        var sources: [StagingAssetSource] = []
        result.enumerateObjects { asset, _, _ in sources.append(Self.source(asset, resources: PHAssetResource.assetResources(for: asset))) }
        return (current.localizedTitle ?? "未命名相簿", sources)
    }
    private func checkedResources(_ expected: StagingAssetSource) throws -> [PHAssetResource] {
        try checkPermission()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [expected.identifier], options: nil).firstObject else {
            throw ExportError.invalidManifest("来源照片已不可访问")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard Self.source(asset, resources: resources) == expected else {
            throw ExportError.invalidManifest("照片编辑或资源目录已变化，停止以免混合新旧版本")
        }
        return resources
    }
    func refreshCandidates(collection: PHAssetCollection) async {
        guard !busy, FileManager.default.fileExists(atPath: exports.path) else { return }
        let root = exports; let identifier = collection.localIdentifier
        candidates = (try? await Task.detached(priority: .utility) {
            try StagingResume.requireDirectory(root)
            return try FileManager.default.contentsOfDirectory(atPath: root.path).compactMap { name -> StagingCandidate? in
                guard UUID(uuidString: name) != nil,
                      let loaded = try? StagingResume.load(in: root.appendingPathComponent(name)),
                      loaded.plan.sourceOrder.albumIdentifier == identifier else { return nil }
                return StagingCandidate(id: name, capturedAt: loaded.plan.sourceOrder.capturedAt)
            }.sorted { $0.capturedAt > $1.capturedAt }
        }.value) ?? []
    }
    func start(collection: PHAssetCollection, allowNetwork: Bool, resumeSession: String? = nil, stopAfterResources: Int? = nil) async {
        guard !busy else { return }
        busy = true; stopRequested = false; resourcesCompleted = 0; totalResources = 0; bytesCompleted = 0
        reusedResources = 0; photoKitResourcesRead = 0; sessionName = nil
        defer { busy = false }
        var directory: URL?; var previous: URL?; var previousDigest: String?
        let build = Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned"
        func journal(_ state: String, error: String? = nil) throws {
            guard let directory else { return }
            var value: [String: Any] = ["status": state, "resourcesCompleted": resourcesCompleted,
                "bytesCompleted": bytesCompleted, "reusedVerifiedResources": reusedResources,
                "photoKitResourcesRead": photoKitResourcesRead, "partialResourceBytesReused": 0,
                "networkAllowed": allowNetwork, "restoration": "NOT_RUN", "originalMediaModified": false,
                "runningBuild": build, "oldStagingSessionWritten": false]
            if let resumeSession { value["resumedFromSession"] = resumeSession }
            if let previousDigest { value["previousPlanSHA256"] = previousDigest }
            if let error { value["error"] = error }
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("export-progress.json"), options: .atomic)
        }
        do {
            try checkPermission()
            let captured = try capture(collection); let sources = captured.assets
            guard !sources.isEmpty else { throw ExportError.invalidManifest("相簿为空或不可访问") }
            totalResources = sources.reduce(0) { $0 + $1.resources.count }
            let name = captured.name
            var snapshot = OrderSnapshot(albumName: name, albumIdentifier: collection.localIdentifier,
                authorization: "full", fetchMode: "nil-options", identifiers: sources.map(\.identifier),
                creationDates: sources.map(\.creationDate), systemVersion: UIDevice.current.systemVersion, build: build)
            if !FileManager.default.fileExists(atPath: exports.path) {
                try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: false)
            }
            try StagingResume.requireDirectory(exports)
            var reusable: [String: ExportResource] = [:]
            if let resumeSession {
                guard UUID(uuidString: resumeSession) != nil, !resumeSession.contains("/") else { throw ExportError.invalidManifest("无效暂存会话") }
                let old = exports.appendingPathComponent(resumeSession)
                let loaded = try await Task.detached(priority: .utility) { try StagingResume.load(in: old) }.value
                try loaded.plan.validateCurrent(albumIdentifier: collection.localIdentifier, albumName: name, assets: sources)
                reusable = try await Task.detached(priority: .utility) {
                    try StagingResume.reusable(in: old, plan: loaded.plan, digest: loaded.digest)
                }.value
                previous = old; previousDigest = loaded.digest; snapshot = loaded.plan.sourceOrder
                // Source may have changed while hashing the old session.
                let current = try capture(collection)
                try loaded.plan.validateCurrent(albumIdentifier: collection.localIdentifier, albumName: current.name, assets: current.assets)
            }
            try checkStopAndPermission()
            let session = UUID().uuidString; let dir = exports.appendingPathComponent(session)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            directory = dir; sessionName = session
            let plan = StagingPlan(sessionID: session, sourceOrder: snapshot, assets: sources)
            let digest = try StagingResume.prepare(plan: plan, in: dir)
            try snapshot.json().write(to: dir.appendingPathComponent("source-order.json"), options: .withoutOverwriting)
            let records = dir.appendingPathComponent("asset-records")
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
            try journal("EXPORTING")
            var groups: [ExportAsset] = []
            for (index, source) in sources.enumerated() {
                var exported: [ExportResource] = []
                for resourceIndex in source.resources.indices {
                    try checkStopAndPermission()
                    let resources = try checkedResources(source); let resource = resources[resourceIndex]
                    let relative = ResourcePaths.make(ordinal: index + 1, resourceIndex: resourceIndex + 1, originalFilename: resource.originalFilename)
                    let completed: ExportResource
                    if let cached = reusable[relative], let previous {
                        message = "正在准备第 \(index + 1) 张照片"
                        try await Task.detached(priority: .utility) { try StagingResume.copy(cached, from: previous, to: dir) }.value
                        completed = cached
                    } else {
                        let destination = dir.appendingPathComponent(relative); let part = destination.appendingPathExtension("part")
                        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try StagingResume.requireDirectory(destination.deletingLastPathComponent())
                        guard !FileManager.default.fileExists(atPath: part.path), !FileManager.default.fileExists(atPath: destination.path) else {
                            throw ExportError.invalidManifest("暂存路径冲突，停止以避免覆盖")
                        }
                        message = "正在保存第 \(index + 1)/\(sources.count) 张照片，第 \(resourceIndex + 1)/\(resources.count) 个文件"
                        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowNetwork
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            PHAssetResourceManager.default().writeData(for: resource, toFile: part, options: options) { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            }
                        }
                        _ = try checkedResources(source)
                        let receipt = try await Task.detached(priority: .utility) { try ProbeFiles.inspect(part) }.value
                        guard receipt.byteCount > 0 else { throw ExportError.invalidManifest("原始资源为空") }
                        try StagingFiles.commit(part: part, destination: destination)
                        completed = ExportResource(resourceIndex: resourceIndex + 1, resourceType: resource.type.rawValue,
                            originalFilename: resource.originalFilename, uniformTypeIdentifier: resource.uniformTypeIdentifier,
                            storedRelativePath: relative, sha256: receipt.sha256, byteCount: receipt.byteCount)
                    }
                    _ = try checkedResources(source)
                    try await Task.detached(priority: .utility) {
                        try StagingResume.record(completed, ordinal: index + 1, plan: plan, digest: digest, in: dir)
                    }.value
                    exported.append(completed); resourcesCompleted += 1; bytesCompleted += completed.byteCount
                    if reusable[relative] != nil { reusedResources += 1 } else { photoKitResourcesRead += 1 }
                    try journal("EXPORTING")
                    if let limit = stopAfterResources, resourcesCompleted >= limit { stopRequested = true }
                }
                let group = ExportAsset(ordinal: index + 1, resourceGroupId: UUID().uuidString,
                    sourceAssetLocalIdentifier: source.identifier, originalPhotoLibraryCreationDate: source.creationDate,
                    pixelWidth: source.pixelWidth, pixelHeight: source.pixelHeight, mediaType: source.mediaType,
                    mediaSubtypes: source.mediaSubtypes, resources: exported)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(group).write(to: records.appendingPathComponent(String(format: "%06d.json", index + 1)), options: .withoutOverwriting)
                groups.append(group)
            }
            try checkStopAndPermission()
            let checked = try await Task.detached(priority: .utility) { try StagingResume.reusable(in: dir, plan: plan, digest: digest) }.value
            guard checked.count == resourcesCompleted else { throw ExportError.invalidManifest("完成资源与检查点数量不一致") }
            if let previous, let previousDigest {
                guard try StagingResume.load(in: previous).digest == previousDigest else { throw ExportError.invalidManifest("旧会话计划已变化") }
            }
            let current = try capture(collection)
            try plan.validateCurrent(albumIdentifier: collection.localIdentifier, albumName: current.name, assets: current.assets, requireEditVersion: resumeSession != nil)
            try checkStopAndPermission()
            let manifest = AlbumExportManifest(sessionID: session, sourceOrder: snapshot, assets: groups)
            try journal("READY_TO_COMMIT")
            let manifestPart = dir.appendingPathComponent("album-order.json.part")
            try manifest.json().write(to: manifestPart, options: .withoutOverwriting)
            try StagingFiles.commit(part: manifestPart, destination: dir.appendingPathComponent("album-order.json"))
            try journal("STAGED")
            message = "保存完成：\(sources.count) 张照片，\(resourcesCompleted) 个文件已检查。等待 Mac 保存。"
        } catch {
            let e = error as NSError; let detail = "\(e.domain) / \(e.code)：\(e.localizedDescription)"
            try? journal(stopRequested ? "STOPPED" : "FAILED", error: detail)
            message = "没有完成：\(detail)。已完成和部分暂存均保留；可以查找上次进度继续。旧版本的备份不能继续，云端原图可能需要打开下载选项。"
        }
    }
    private func checkPermission() throws {
        try PhotoOperationChecks.requireFullAccess()
    }
    private func checkStopAndPermission() throws {
        if stopRequested || Task.isCancelled { throw ExportError.invalidManifest("已暂停，之前的进度已保留，可以查找后继续") }
        try checkPermission()
    }
}
