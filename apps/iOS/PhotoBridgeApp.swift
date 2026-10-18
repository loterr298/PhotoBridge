import SwiftUI
import Photos
import PhotoBridgeCore

@main struct PhotoBridgeApp: App {
    @StateObject private var library = LibraryProbe()
    var body: some Scene {
        WindowGroup {
            TabView {
                AlbumsView().tabItem { Label("相册", systemImage: "photo.on.rectangle") }
                USBProbeView().tabItem { Label("传输", systemImage: "arrow.left.arrow.right") }
                NavigationStack {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle)
                        Text("恢复功能尚未启用").font(.title2)
                        Text("当前支持原始资源暂存与 USB 校验；照片库导回和恢复尚未实现。")
                    }.padding().navigationTitle("恢复")
                }.tabItem { Label("恢复", systemImage: "clock.arrow.circlepath") }
                NavigationStack {
                    Form {
                        Section("当前版本 · M1 导出验证") {
                            Text("只读取相簿，不修改或删除照片")
                            Text("不改 EXIF、GPS、MakerNotes 或照片显示时间")
                            Text("清单和资源仅本地暂存，可经已信任 Mac 的 USB 文件共享复制")
                        }
                        Section("原始资源导出策略") {
                            Text("原始资源字节 + SHA-256")
                            Text("5 秒步长仅用于 Mac 文件系统时间")
                        }
                    }.navigationTitle("设置")
                }.tabItem { Label("设置", systemImage: "gearshape") }
            }.environmentObject(library)
        }
    }
}

struct AlbumItem: Identifiable {
    var id: String { collection.localIdentifier }
    let collection: PHAssetCollection
    let count: Int
    let cover: PHAsset?
}

enum FetchMode: String, CaseIterable, Identifiable {
    case defaults = "nil-options", empty = "empty-options"
    var id: String { rawValue }
    var label: String { self == .defaults ? "默认选项（nil）" : "空 PHFetchOptions" }
    var options: PHFetchOptions? { self == .defaults ? nil : PHFetchOptions() }
}

@MainActor final class LibraryProbe: ObservableObject {
    @Published var albums: [AlbumItem] = []
    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var message = "读取自建普通相簿，顺序待人工核验"
    var permissionName: String {
        switch authorization { case .authorized: return "full"; case .limited: return "limited"
        case .denied: return "denied"; case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"; @unknown default: return "unknown" }
    }
    func request() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite); reload()
    }
    func reload() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        albums = []
        guard authorization == .authorized || authorization == .limited else {
            message = "需要照片权限，请在设置中允许读取"; return
        }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            self.albums.append(AlbumItem(collection: collection, count: assets.count, cover: assets.firstObject))
        }
        message = authorization == .limited ? "受限照片权限：成员可能缺失，不能通过全相簿验收" : "全库权限 · 顺序读取待验证"
    }
    func read(_ collection: PHAssetCollection, mode: FetchMode) -> (OrderSnapshot, [PHAsset]) {
        let result = PHAsset.fetchAssets(in: collection, options: mode.options)
        var assets: [PHAsset] = []; assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let build = Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned"
        return (OrderSnapshot(albumName: collection.localizedTitle ?? "未命名相簿",
                              albumIdentifier: collection.localIdentifier, authorization: permissionName,
                              fetchMode: mode.rawValue, identifiers: assets.map(\.localIdentifier),
                              creationDates: assets.map(\.creationDate), systemVersion: UIDevice.current.systemVersion,
                              build: build), assets)
    }
}

struct AlbumsView: View {
    @EnvironmentObject var library: LibraryProbe
    @Environment(\.scenePhase) private var scene
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("USB 链路状态由 Mac 端检测").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Mac 连接诊断", systemImage: "laptopcomputer").font(.headline)
                        Text("先核对相簿顺序，再导出原始资源").foregroundStyle(.secondary)
                        Button("读取照片相簿") { Task { await library.request() } }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Text("进入相簿可导出原始资源；导回尚未启用").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    Text("相簿").font(.title.bold())
                    Text(library.message).font(.subheadline).foregroundStyle(.secondary)
                    LazyVStack(spacing: 12) {
                        ForEach(library.albums) { item in
                            NavigationLink { AlbumProbeView(collection: item.collection) } label: {
                                HStack(spacing: 16) {
                                    AssetThumbnail(asset: item.cover).frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.collection.localizedTitle ?? "未命名相簿").font(.headline).foregroundStyle(.primary)
                                        Text("\(item.count) 个可见成员").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 24))
                            }.buttonStyle(.plain)
                        }
                    }
                    Label("顺序读取待验证", systemImage: "arrow.up.arrow.down").foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("照片传输")
                .toolbar { Button("刷新") { library.reload() } }
                .task { library.reload() }.onChange(of: scene) { if $0 == .active { library.reload() } }
        }
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset?
    @State private var image: UIImage?
    @State private var request: PHImageRequestID = PHInvalidImageRequestID
    @State private var generations = RequestGeneration()
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel("缩略图未就绪") }
        }.clipped().task(id: asset?.localIdentifier) {
            PHImageManager.default().cancelImageRequest(request)
            let token = generations.begin()
            image = nil
            if let asset {
                let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false
                request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 240, height: 240),
                    contentMode: .aspectFill, options: options) { result, _ in
                        DispatchQueue.main.async {
                            guard generations.accepts(token) else { return }
                            image = result
                        }
                    }
            }
        }.onDisappear {
            generations.invalidate()
            PHImageManager.default().cancelImageRequest(request)
        }
    }
}

struct AlbumProbeView: View {
    let collection: PHAssetCollection
    @EnvironmentObject var library: LibraryProbe
    @Environment(\.scenePhase) private var scene
    @State private var mode = FetchMode.defaults
    @State private var snapshot: OrderSnapshot?
    @State private var assets: [PHAsset] = []
    @State private var exportURL: URL?
    @State private var error: String?
    @State private var showOriginalExport = false
    var body: some View {
        List {
            Section("读取方式 · 不指定排序字段") {
                Picker("选项", selection: $mode) { ForEach(FetchMode.allCases) { Text($0.label).tag($0) } }
                Text("索引是 PhotoKit 原始返回位置，不代表已通过系统照片比对。")
                Text("\(assets.count) 个可见成员 · \(library.permissionName)")
                Button("重新读取") { reload() }
                Button("保存本地诊断 JSON") { save() }.disabled(snapshot == nil)
                if let exportURL { ShareLink("主动分享诊断文件", item: exportURL) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("与照片 App 人工逐项核对") {
                Text("在系统照片中选自定义顺序。用有醒目编号的 20 张测试照片核对下方位置与编号，独立填比较表。移动五张后重新读取。两种读取方式分别测试。")
                Text("受限权限、智能/共享相簿和系统图库视图不属于全相簿通过范围。")
            }
            Section("原始资源 · M1 设备待验证") {
                Button("导出原始资源到本机暂存") { showOriginalExport = true }
                    .disabled(library.authorization != .authorized)
                Text("全部资源逐项 SHA-256；不转码、不改内部元数据。完整照片往返尚未验证。")
            }
            Section("相簿标识") { Text(collection.localIdentifier).font(.caption.monospaced()).textSelection(.enabled) }
            ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                HStack(alignment: .top) {
                    AssetThumbnail(asset: asset).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(String(format: "%04d", index + 1)).font(.headline.monospacedDigit())
                        Text(asset.localIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                        if let date = asset.creationDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    }
                }.accessibilityElement(children: .combine)
            }
        }.navigationTitle(collection.localizedTitle ?? "相簿诊断")
            .sheet(isPresented: $showOriginalExport) { OriginalExportView(collection: collection) }
            .task { reload() }.onChange(of: mode) { _ in reload() }
            .onChange(of: scene) { if $0 == .active { reload() } }
    }
    private func reload() {
        exportURL = nil; error = nil; snapshot = nil; assets = []
        library.reload()
        guard library.authorization == .authorized || library.authorization == .limited else { return }
        let value = library.read(collection, mode: mode); snapshot = value.0; assets = value.1
    }
    private func save() {
        do {
            guard let snapshot else { return }
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OrderProbe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            let url = dir.appendingPathComponent("order-probe.json")
            try snapshot.json().write(to: url, options: .withoutOverwriting); exportURL = url
        } catch { self.error = error.localizedDescription }
    }
}
