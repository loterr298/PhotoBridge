import SwiftUI
import Photos
import PhotoBridgeCore

@main
struct PhotoBridgeApp: App {
    @StateObject private var library = LibraryProbe()
    var body: some Scene {
        WindowGroup {
            TabView {
                AlbumsView().tabItem { Label("备份到 Mac", systemImage: "arrow.down.to.line.compact") }.tag(0)
                RestoreView().tabItem { Label("导入到 iPhone", systemImage: "arrow.up.to.line.compact") }.tag(1)
                PhotoInfoView().tabItem { Label("照片信息", systemImage: "slider.horizontal.3") }.tag(2)
            }
            .tint(.bridgeBlue)
            .environmentObject(library)
        }
    }
}

struct AlbumItem: Identifiable {
    var id: String { collection.localIdentifier }
    let collection: PHAssetCollection
    let count: Int
    let cover: PHAsset?
    let previews: [PHAsset]
}

enum FetchMode: String, CaseIterable, Identifiable {
    case defaults = "nil-options", empty = "empty-options"
    var id: String { rawValue }
    var label: String { self == .defaults ? "默认选项（nil）" : "空 PHFetchOptions" }
    var options: PHFetchOptions? { self == .defaults ? nil : PHFetchOptions() }
}

@MainActor
final class LibraryProbe: ObservableObject {
    @Published var albums: [AlbumItem] = []
    @Published var authorization: PHAuthorizationStatus = .notDetermined
    @Published var message = "准备查看你的相册"
    var permissionName: String {
        switch authorization { case .authorized: return "full"; case .limited: return "limited"
        case .denied: return "denied"; case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"; @unknown default: return "unknown" }
    }
    func request() async { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite); reload() }
    func reload() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        albums = []
        guard authorization == .authorized || authorization == .limited else {
            message = "请允许访问照片，才能显示你的相册"; return
        }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var previews: [PHAsset] = []; previews.reserveCapacity(3)
            assets.enumerateObjects { asset, index, stop in
                if index < 3 { previews.append(asset) } else { stop.pointee = true }
            }
            self.albums.append(AlbumItem(collection: collection, count: assets.count, cover: previews.first, previews: previews))
        }
        message = authorization == .limited ? "当前只显示你选中的照片" : "相册已准备好"
    }
    func read(_ collection: PHAssetCollection, mode: FetchMode) -> (OrderSnapshot, [PHAsset]) {
        let result = PHAsset.fetchAssets(in: collection, options: mode.options)
        var assets: [PHAsset] = []; assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        let build = Bundle.main.object(forInfoDictionaryKey: "PhotoBridgeBuildCommit") as? String ?? "local-unversioned"
        return (OrderSnapshot(albumName: collection.localizedTitle ?? "未命名相簿", albumIdentifier: collection.localIdentifier, authorization: permissionName,
                              fetchMode: mode.rawValue, identifiers: assets.map(\.localIdentifier), creationDates: assets.map(\.creationDate),
                              systemVersion: UIDevice.current.systemVersion, build: build), assets)
    }
}

struct AlbumsView: View {
    @EnvironmentObject private var library: LibraryProbe
    @State private var showAll = false
    @State private var showRestore = false
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("备份照片到 Mac").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                                BridgeStatus(title: library.authorization == .authorized ? "照片已准备 · 等待数据线" : "请先允许访问照片", connected: false)
                            }
                            Spacer()
                            Menu {
                                Button("重新读取相册") { library.reload() }
                            } label: {
                                Image(systemName: "ellipsis").font(.title3.weight(.bold)).foregroundStyle(Color.bridgeMuted).frame(width: 46, height: 46).background(.white.opacity(0.68), in: Circle())
                            }
                        }

                        BridgeCard {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 14) {
                                    BridgeIconCircle(systemImage: "laptopcomputer", tint: .bridgeBlue, size: 62)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("连接 Mac 后开始备份").font(.title3.weight(.semibold))
                                        Text("用数据线连接 Mac，照片不会上传云端").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Circle().fill(.gray.opacity(0.55)).frame(width: 11, height: 11)
                                }
                                NavigationLink { AlbumTransferPicker() } label: {
                                    Label("选择相册开始备份", systemImage: "photo.on.rectangle.angled")
                                        .frame(maxWidth: .infinity)
                                }.buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                            }
                        }

                        HStack(alignment: .firstTextBaseline) {
                            Text("选择相册").font(.title2.bold()).foregroundStyle(Color.bridgeInk)
                            Spacer()
                            Button(showAll ? "收起" : "查看全部") { withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() } }
                                .font(.subheadline.weight(.medium)).foregroundStyle(Color.bridgeMuted)
                        }

                        if library.albums.isEmpty {
                            BridgeCard {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(library.message).foregroundStyle(.secondary)
                                    BridgePrimaryButton(action: { Task { await library.request() } }) { Text("允许访问照片") }
                                }
                            }
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(showAll ? library.albums : Array(library.albums.prefix(3))) { item in
                                    NavigationLink { OriginalExportView(collection: item.collection) } label: {
                                        AlbumRow(item: item)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }

                        if let first = library.albums.first {
                            BridgeCard {
                                HStack(spacing: 14) {
                                    BridgeIconCircle(systemImage: "arrow.up.arrow.down", tint: .bridgeBlue, size: 52)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("顺序保留").font(.headline)
                                        Text("按系统照片中的当前顺序保存，不在这里重新排序").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    HStack(spacing: 4) {
                                        ForEach(Array(first.previews.enumerated()), id: \.element.localIdentifier) { index, asset in
                                            ZStack(alignment: .bottomTrailing) {
                                                AssetThumbnail(asset: asset).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                                                Text(String(format: "%04d", index + 1)).font(.system(size: 7, weight: .semibold, design: .monospaced)).foregroundStyle(.white).padding(2).background(.black.opacity(0.55), in: Capsule())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 28)
                }
            }
            .navigationBarHidden(true)
            .task { library.reload() }
        }
    }
}

struct AlbumRow: View {
    let item: AlbumItem
    var body: some View {
        HStack(spacing: 14) {
            AssetThumbnail(asset: item.cover).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.collection.localizedTitle ?? "未命名相册").font(.headline).foregroundStyle(Color.bridgeInk)
                Text("\(item.count) 张照片").font(.subheadline).foregroundStyle(Color.bridgeMuted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(Color.bridgeMuted)
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1))
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
