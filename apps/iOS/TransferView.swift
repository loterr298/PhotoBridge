import SwiftUI
import Photos
import PhotoBridgeCore

@MainActor
final class TransferHistoryModel: ObservableObject {
    @Published var sessions: [TransferSessionSummary] = []
    private var exports: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
    }

    func reload() {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            sessions = []; return
        }
        sessions = directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let progressURL = directory.appendingPathComponent("export-progress.json")
            guard let data = try? Data(contentsOf: progressURL),
                  var summary = try? TransferSessionSummary.decode(data, identifier: directory.lastPathComponent) else { return nil }
            let sourceOrder = directory.appendingPathComponent("source-order.json")
            let sourceObject = (try? Data(contentsOf: sourceOrder)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let albumName = sourceObject?["albumName"] as? String
            if let manifest = try? Data(contentsOf: directory.appendingPathComponent("album-order.json")),
               let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
               let assets = object["assets"] as? [[String: Any]] {
                let resources = assets.compactMap { $0["resources"] as? [[String: Any]] }.flatMap { $0 }
                let totalBytes = resources.compactMap { ($0["byteCount"] as? NSNumber)?.int64Value }.reduce(0, +)
                let manifestSource = object["sourceOrder"] as? [String: Any]
                summary = TransferSessionSummary(identifier: summary.identifier, status: summary.status,
                    completed: summary.completed, total: resources.count, bytes: summary.bytes,
                    totalBytes: totalBytes, currentResource: summary.currentResource, error: summary.error,
                    albumName: (manifestSource?["albumName"] as? String) ?? albumName)
            } else if let albumName {
                summary = TransferSessionSummary(identifier: summary.identifier, status: summary.status,
                    completed: summary.completed, total: summary.total, bytes: summary.bytes,
                    totalBytes: summary.totalBytes, currentResource: summary.currentResource,
                    error: summary.error, albumName: albumName)
            }
            return summary
        }.sorted { $0.identifier > $1.identifier }
    }
}

struct TransferView: View {
    @EnvironmentObject private var library: LibraryProbe
    @Environment(\.scenePhase) private var scene
    @StateObject private var history = TransferHistoryModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("传输").font(.largeTitle.bold())
                            Text("把照片保存到 Mac，随时可以继续")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("等待 Mac 连接", systemImage: "cable.connector")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.1), in: Capsule())
                        }
                        Text("iPhone 先准备照片，Mac 再保存到你选择的文件夹。原照片始终保留。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        NavigationLink {
                            AlbumTransferPicker()
                        } label: {
                            Label("备份一个相册", systemImage: "arrow.down.to.line.compact")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        NavigationLink {
                            BatchExportView()
                        } label: {
                            Label("同时备份多个相册", systemImage: "checklist")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))

                    HStack {
                        Text("最近备份").font(.title2.bold())
                        Spacer()
                        Button("刷新") { history.reload() }
                            .font(.subheadline)
                    }
                    if history.sessions.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("还没有备份")
                                .font(.headline)
                            Text("选择一个相册，照片会显示在这里。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(history.sessions) { summary in
                                TransferSessionCard(summary: summary)
                            }
                        }
                    }

                    NavigationLink {
                        USBProbeView()
                    } label: {
                        Label("连接帮助", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    Text("遇到连接问题？打开连接帮助，按提示检查数据线和信任设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("备份")
            .task { library.reload(); history.reload() }
            .onChange(of: scene) { if $0 == .active { history.reload() } }
        }
    }
}

struct AlbumTransferPicker: View {
    @EnvironmentObject private var library: LibraryProbe
    var body: some View {
        List {
            Section("选择来源相簿") {
                if library.albums.isEmpty {
                    Button("读取照片相簿") { Task { await library.request() } }
                }
                ForEach(library.albums) { item in
                    NavigationLink {
                        OriginalExportView(collection: item.collection)
                    } label: {
                        HStack(spacing: 14) {
                            AssetThumbnail(asset: item.cover)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.collection.localizedTitle ?? "未命名相簿")
                                    .foregroundStyle(.primary)
                                Text("\(item.count) 个成员")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("选择相簿")
        .task { library.reload() }
    }
}

struct TransferSessionCard: View {
    let summary: TransferSessionSummary
    private var stateLabel: String {
        switch summary.status {
        case "STAGED", "VERIFIED", "COMMITTED": return "已保存"
        case "EXPORTING", "DOWNLOADING", "UPLOADING": return "正在保存"
        case "STOPPED": return "已暂停，可继续"
        case "FAILED": return "保存失败"
        default: return "处理中"
        }
    }
    private var tint: Color {
        switch summary.status {
        case "STAGED", "VERIFIED", "COMMITTED": return .green
        case "FAILED": return .red
        default: return .blue
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(stateLabel, systemImage: summary.status == "FAILED" ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(tint)
                Spacer()
                Text(String(summary.identifier.prefix(8)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let albumName = summary.albumName, !albumName.isEmpty {
                Text(albumName).font(.headline)
            }
            if summary.totalBytes > 0 {
                ProgressView(value: summary.fraction)
                HStack {
                    Text("\(summary.completed)/\(summary.total) 项")
                    Text("\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else {
                Text("已保存 \(summary.completed) 项")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = summary.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }
}
