import SwiftUI
import Photos
import PhotoBridgeCore

@MainActor
final class BatchExportModel: ObservableObject {
    @Published var running = false
    @Published var current = ""
    @Published var result = ""
    @Published var completedAlbums = 0
    @Published var totalAlbums = 0
    @Published var resourcesCompleted = 0
    @Published var bytesCompleted = 0
    @Published var detail = ""
    @Published var allowNetwork = false
    let exporter = OriginalExportService()

    func start(albums: [AlbumItem]) async {
        guard !running else { return }
        let chosen = albums.filter { selectedIDs.contains($0.id) }
        do {
            _ = try BatchQueuePlan(identifiers: chosen.map(\.id))
        } catch {
            result = error.localizedDescription; return
        }
        running = true; result = ""; completedAlbums = 0; totalAlbums = chosen.count
        for item in chosen {
            current = item.collection.localizedTitle ?? "未命名相簿"
            resourcesCompleted = 0; bytesCompleted = 0; detail = "准备保存照片…"
            let monitor = Task { @MainActor [weak self] in
                while let self, self.exporter.busy {
                    self.resourcesCompleted = self.exporter.resourcesCompleted
                    self.bytesCompleted = self.exporter.bytesCompleted
                    self.detail = self.exporter.message
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            await exporter.start(collection: item.collection, allowNetwork: allowNetwork)
            monitor.cancel()
            resourcesCompleted = exporter.resourcesCompleted
            bytesCompleted = exporter.bytesCompleted
            detail = exporter.message
            if exporter.message.hasPrefix("未完成") {
                result = exporter.message
                break
            }
            completedAlbums += 1
        }
        if result.isEmpty { result = "已完成：\(completedAlbums)/\(totalAlbums) 个相册。" }
        running = false; current = ""
    }

    func requestStop() { exporter.requestStop() }

    @Published var selectedIDs = Set<String>()
}

struct BatchExportView: View {
    @EnvironmentObject private var library: LibraryProbe
    @StateObject private var model = BatchExportModel()
    var body: some View {
        List {
            Section {
                Toggle("需要时从云端下载原图", isOn: $model.allowNetwork)
                    .disabled(model.running)
                Text("会按你选择的顺序逐个保存。中途停止后，可以从上次的位置继续。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("选择相册") {
                if library.albums.isEmpty {
                    Button("查看我的相册") { Task { await library.request() } }
                }
                ForEach(library.albums) { item in
                    Toggle(isOn: Binding(get: {
                        model.selectedIDs.contains(item.id)
                    }, set: { selected in
                        if selected { model.selectedIDs.insert(item.id) }
                        else { model.selectedIDs.remove(item.id) }
                    })) {
                        HStack(spacing: 12) {
                            AssetThumbnail(asset: item.cover)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.collection.localizedTitle ?? "未命名相簿")
                                Text("\(item.count) 张照片")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(model.running)
                }
            }
            Section("备份进度") {
                if model.running {
                    ProgressView(value: Double(model.completedAlbums), total: Double(max(1, model.totalAlbums)))
                    Text("正在保存：\(model.current)")
                    Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text("已保存 \(model.resourcesCompleted) 项 · \(ByteCountFormatter.string(fromByteCount: Int64(model.bytesCompleted), countStyle: .file))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("暂停并保留进度") { model.requestStop() }
                }
                if !model.result.isEmpty { Text(model.result).textSelection(.enabled) }
                Text("已完成 \(model.completedAlbums)/\(model.totalAlbums) 个相册")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Section {
                Button("开始备份") {
                    Task { await model.start(albums: library.albums) }
                }
                .disabled(model.running || model.selectedIDs.isEmpty || library.authorization != .authorized)
            }
        }
        .navigationTitle("批量备份")
        .task { library.reload() }
    }
}
