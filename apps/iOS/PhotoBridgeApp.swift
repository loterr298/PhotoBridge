import SwiftUI
import Photos
import PhotoBridgeCore

@main struct PhotoBridgeApp: App {
    @StateObject private var library = LibraryProbe()
    var body: some Scene {
        WindowGroup {
            TabView {
                AlbumsView().tabItem { Label("相册", systemImage: "photo.on.rectangle") }
                TransferView().tabItem { Label("备份", systemImage: "arrow.left.arrow.right") }
                RestoreView().tabItem { Label("恢复", systemImage: "clock.arrow.circlepath") }
                SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
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
    @Published var message = "准备好查看你的相册"
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
            message = "请允许访问照片，才能显示你的相册"; return
        }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            self.albums.append(AlbumItem(collection: collection, count: assets.count, cover: assets.firstObject))
        }
        message = authorization == .limited ? "当前只显示你选中的照片" : "相册已准备好"
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
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("照片传输").font(.largeTitle.bold())
                                Text("把照片安全保存到 Mac")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("等待连接 Mac", systemImage: "cable.connector")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                        HStack(spacing: 12) {
                            Label("保留原图", systemImage: "lock.shield")
                            Label("逐张检查", systemImage: "checkmark.shield")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("查看我的相册") { Task { await library.request() } }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            NavigationLink("从 Mac 恢复") { RestoreView() }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                        Text("用数据线连接 iPhone 后，Mac 会自动检查连接状态。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color.white.opacity(0.45)))
                    .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
                    Text("我的相册").font(.title.bold())
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
                    Label("照片顺序会按相册原样保存", systemImage: "arrow.up.arrow.down")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
            Section("相册顺序") {
                Text("按系统照片中的当前顺序显示，共 \(assets.count) 张")
                Button("重新读取") { reload() }
                Button("保存详细记录") { save() }.disabled(snapshot == nil)
                if let exportURL { ShareLink("分享详细记录", item: exportURL) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            Section("确认顺序") {
                Text("打开系统“照片”，选择自定义顺序，再和下面的缩略图从第 1 张开始逐张核对。移动几张照片后重新读取即可再次确认。")
                Text("相册顺序以系统照片为准；这里只显示读取到的结果。")
            }
            Section("保存照片") {
                Button("开始保存到 Mac") { showOriginalExport = true }
                    .disabled(library.authorization != .authorized)
                Text("完整保存原图和 Live Photo，不压缩、不改变照片里的拍摄信息。")
            }
            Section("照片顺序") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 4)], spacing: 4) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        NavigationLink {
                            AssetDetailView(asset: asset, ordinal: index + 1)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                AssetThumbnail(asset: asset)
                                    .frame(height: 104)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(String(format: "%04d", index + 1))
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 4)
                                    .background(.black.opacity(0.58), in: Capsule())
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("点按照片查看详情。编号就是它在相册中的位置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("查看详细信息") {
                Text("相册内部编号").font(.caption).foregroundStyle(.secondary)
                Text(collection.localIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                    HStack(alignment: .top) {
                        Text(String(format: "%04d", index + 1)).font(.caption.monospacedDigit())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.localIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                            if let date = asset.creationDate { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }.navigationTitle(collection.localizedTitle ?? "相册详情")
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

struct AssetDetailView: View {
    let asset: PHAsset
    let ordinal: Int
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AssetThumbnail(asset: asset)
                    .frame(maxWidth: .infinity).frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                Text(String(format: "第 %d 张", ordinal)).font(.title2.bold())
                if let date = asset.creationDate {
                    Label(date.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("照片文件")
                        .font(.headline)
                    ForEach(Array(PHAssetResource.assetResources(for: asset).enumerated()), id: \.offset) { index, resource in
                        HStack {
                            Text("\(index + 1)").font(.caption.monospacedDigit())
                            Text(resource.originalFilename).lineLimit(1)
                            Spacer()
                            Text(resource.type == .photo ? "照片" : "配套文件").font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                }
                Text("这些是照片包含的文件。保存时会逐个检查，确保没有缺少。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .navigationTitle("照片详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
