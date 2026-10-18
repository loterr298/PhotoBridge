import SwiftUI
import Photos
import PhotoBridgeCore

@MainActor final class OriginalExportService: ObservableObject {
    @Published var busy = false
    @Published var message = "尚未导出"
    @Published var resourcesCompleted = 0
    @Published var bytesCompleted = 0
    @Published var sessionName: String?
    private var stopRequested = false

    func requestStop() { stopRequested = true }
    func start(collection: PHAssetCollection, allowNetwork: Bool) async {
        guard !busy else { return }
        busy = true; stopRequested = false; resourcesCompleted = 0; bytesCompleted = 0; sessionName = nil
        defer { busy = false }
        var directory: URL?
        func journal(_ state: String, error: String? = nil) throws {
            guard let directory else { return }
            var value: [String: Any] = ["status": state, "resourcesCompleted": resourcesCompleted,
                "bytesCompleted": bytesCompleted, "networkAllowed": allowNetwork,
                "restoration": "NOT_RUN", "originalMediaModified": false]
            if let error { value["error"] = error }
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("export-progress.json"), options: .atomic)
        }
        do {
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw ExportError.invalidManifest("完整相簿导出需要全部照片权限")
            }
            let fetched = PHAsset.fetchAssets(in: collection, options: nil)
            var assets: [PHAsset] = []; fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
            guard !assets.isEmpty else { throw ExportError.invalidManifest("相簿为空或不可访问") }
            let initialModified = assets.map(\.modificationDate)
            let build = Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned"
            let snapshot = OrderSnapshot(albumName: collection.localizedTitle ?? "未命名相簿",
                albumIdentifier: collection.localIdentifier, authorization: "full", fetchMode: "nil-options",
                identifiers: assets.map(\.localIdentifier), creationDates: assets.map(\.creationDate),
                systemVersion: UIDevice.current.systemVersion, build: build)
            let session = UUID().uuidString
            let exports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            let dir = exports.appendingPathComponent(session)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            directory = dir; sessionName = session
            try snapshot.json().write(to: dir.appendingPathComponent("source-order.json"), options: .withoutOverwriting)
            let records = dir.appendingPathComponent("asset-records")
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: false)
            try journal("EXPORTING")
            var groups: [ExportAsset] = []
            for (index, asset) in assets.enumerated() {
                try checkStopAndPermission()
                let resources = PHAssetResource.assetResources(for: asset)
                guard !resources.isEmpty else { throw ExportError.invalidManifest("位置 \(index + 1) 没有可访问原始资源") }
                var exported: [ExportResource] = []
                for (resourceIndex, resource) in resources.enumerated() {
                    try checkStopAndPermission()
                    let relative = ResourcePaths.make(ordinal: index + 1, resourceIndex: resourceIndex + 1, originalFilename: resource.originalFilename)
                    let destination = dir.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let part = destination.appendingPathExtension("part")
                    guard !FileManager.default.fileExists(atPath: part.path) && !FileManager.default.fileExists(atPath: destination.path) else {
                        throw ExportError.invalidManifest("暂存路径冲突，已停止以避免覆盖")
                    }
                    message = "正在读取第 \(index + 1)/\(assets.count) 项，第 \(resourceIndex + 1)/\(resources.count) 个资源"
                    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = allowNetwork
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: part, options: options) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    // Hash on a utility worker; media is never decoded/re-encoded.
                    let receipt = try await Task.detached(priority: .utility) { try ProbeFiles.inspect(part) }.value
                    guard receipt.byteCount > 0 else { throw ExportError.invalidManifest("原始资源为空，不能完成") }
                    try StagingFiles.commit(part: part, destination: destination)
                    exported.append(ExportResource(resourceIndex: resourceIndex + 1, resourceType: resource.type.rawValue,
                        originalFilename: resource.originalFilename, uniformTypeIdentifier: resource.uniformTypeIdentifier,
                        storedRelativePath: relative, sha256: receipt.sha256, byteCount: receipt.byteCount))
                    resourcesCompleted += 1; bytesCompleted += receipt.byteCount
                    try journal("EXPORTING")
                }
                let group = ExportAsset(ordinal: index + 1, resourceGroupId: UUID().uuidString,
                    sourceAssetLocalIdentifier: asset.localIdentifier, originalPhotoLibraryCreationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight, mediaType: asset.mediaType.rawValue,
                    mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue), resources: exported)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(group).write(to: records.appendingPathComponent(String(format: "%06d.json", index + 1)), options: .withoutOverwriting)
                groups.append(group)
            }
            try checkStopAndPermission()
            let latest = PHAsset.fetchAssets(in: collection, options: nil)
            var latestIDs: [String] = []; var latestModified: [Date?] = []
            latest.enumerateObjects { asset, _, _ in latestIDs.append(asset.localIdentifier); latestModified.append(asset.modificationDate) }
            guard latestIDs == assets.map(\.localIdentifier) && latestModified == initialModified else {
                throw ExportError.invalidManifest("导出期间相簿顺序、成员或编辑状态改变，未提交完成清单")
            }
            let manifest = AlbumExportManifest(sessionID: session, sourceOrder: snapshot, assets: groups)
            try journal("STAGED")
            let manifestPart = dir.appendingPathComponent("album-order.json.part")
            try manifest.json().write(to: manifestPart, options: .withoutOverwriting)
            try StagingFiles.commit(part: manifestPart, destination: dir.appendingPathComponent("album-order.json"))
            message = "本机暂存完成：\(assets.count) 项、\(resourcesCompleted) 个资源。Mac USB 复制与校验尚未执行；此操作不代表相簿恢复成功。"
        } catch {
            let e = error as NSError
            let detail = "\(e.domain) / \(e.code)：\(e.localizedDescription)"
            try? journal(stopRequested ? "STOPPED" : "FAILED", error: detail)
            message = "未完成：\(detail)。已完成的暂存与部分文件保留，不删除原图；原件在 iCloud 时可能需要显式开启下载。"
        }
    }
    private func checkStopAndPermission() throws {
        if stopRequested || Task.isCancelled { throw ExportError.invalidManifest("已在资源边界停止；本版尚不支持续传") }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw ExportError.invalidManifest("全部照片权限已撤回")
        }
    }
}

struct OriginalExportView: View {
    let collection: PHAssetCollection
    @StateObject private var exporter = OriginalExportService()
    @State private var allowNetwork = false
    @State private var memberCount: Int?
    @State private var freeSpace: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(collection.localizedTitle ?? "原始资源导出") {
                    if let memberCount { Text("本次将导出 \(memberCount) 个相簿成员的全部可访问资源") }
                    if let freeSpace { Text("本机当前可用空间：\(freeSpace)").foregroundStyle(.secondary) }
                    Text("按当前相簿返回位置导出系统提供的全部资源，包括原图、Live Photo 配对视频和可访问的编辑附件。未知资源类型也保留；尚未验证其导回支持。")
                    Text("只写入 App 新建的暂存目录，不改变原照片、EXIF、GPS、MakerNotes 或拍摄时间。请保持 App 前台，并为暂存预留空间。")
                    Toggle("允许从 iCloud 下载原件", isOn: $allowNetwork).disabled(exporter.busy)
                    Text("默认离线。开启后可能使用网络下载；失败会保留错误，绝不替换成缩略图。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("开始导出到本机暂存") {
                        Task { await exporter.start(collection: collection, allowNetwork: allowNetwork) }
                    }.disabled(exporter.busy || memberCount == nil || memberCount == 0)
                    if exporter.busy {
                        ProgressView()
                        Button("完成当前资源后停止") { exporter.requestStop() }
                    }
                }
                Section("真实结果") {
                    Text(exporter.message).textSelection(.enabled)
                    Text("已完成 \(exporter.resourcesCompleted) 个资源 · \(exporter.bytesCompleted) bytes").monospacedDigit()
                    if let session = exporter.sessionName {
                        Text("Mac 读取路径：Exports/\(session)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("Mac 校验后为新副本设置 5 秒间隔的文件系统时间；创建时间按磁盘支持情况验证并记录，不改媒体内部时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("原始资源导出")
        }.task {
            memberCount = PHAsset.fetchAssets(in: collection, options: nil).count
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: docs.path),
               let available = attributes[.systemFreeSize] as? NSNumber {
                freeSpace = ByteCountFormatter.string(fromByteCount: available.int64Value, countStyle: .file)
            }
        }.onDisappear { exporter.requestStop() }
    }
}
