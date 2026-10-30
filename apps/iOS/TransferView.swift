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
                    albumName: (manifestSource?["albumName"] as? String) ?? albumName,
                    elapsedSeconds: summary.elapsedSeconds)
            } else if let albumName {
                summary = TransferSessionSummary(identifier: summary.identifier, status: summary.status,
                    completed: summary.completed, total: summary.total, bytes: summary.bytes,
                    totalBytes: summary.totalBytes, currentResource: summary.currentResource,
                    error: summary.error, albumName: albumName, elapsedSeconds: summary.elapsedSeconds)
            }
            return summary
        }.sorted { $0.identifier > $1.identifier }
    }
}

struct TransferView: View {
    @Environment(\.scenePhase) private var scene
    @StateObject private var history = TransferHistoryModel()
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("传输").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                            Text("查看正在保存和已经保存的照片").foregroundStyle(.secondary)
                        }
                        BridgeCard {
                            HStack(spacing: 14) {
                                BridgeIconCircle(systemImage: "arrow.left.arrow.right", tint: .bridgeBlue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("USB 传输").font(.headline)
                                    Text("iPhone 和 Mac 之间直接传输，不经过云端").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Text("最近保存").font(.title2.bold()).foregroundStyle(Color.bridgeInk)
                            Spacer()
                            Button("刷新") { history.reload() }.foregroundStyle(Color.bridgeBlue)
                        }
                        if history.sessions.isEmpty {
                            BridgeCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("还没有保存记录").font(.headline)
                                    Text("在“相册”里选择相册后开始导出。此处会显示真实进度。") .font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(history.sessions) { summary in TransferSessionCard(summary: summary) }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
            .task { history.reload() }
            .onChange(of: scene) { if $0 == .active { history.reload() } }
        }
    }
}

struct AlbumTransferPicker: View {
    @EnvironmentObject private var library: LibraryProbe
    var body: some View {
        ZStack {
            BridgeBackground()
            ScrollView {
                LazyVStack(spacing: 12) {
                    if library.albums.isEmpty {
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("请允许访问照片").font(.headline)
                                BridgePrimaryButton(action: { Task { await library.request() } }) { Text("读取相册") }
                            }
                        }
                    }
                    ForEach(library.albums) { item in
                        NavigationLink { OriginalExportView(collection: item.collection) } label: { AlbumRow(item: item) }.buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("选择相册")
        .navigationBarTitleDisplayMode(.inline)
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
    private var tint: Color { summary.status == "FAILED" ? .red : (summary.status == "STAGED" || summary.status == "VERIFIED" || summary.status == "COMMITTED" ? .green : .bridgeBlue) }
    var body: some View {
        BridgeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(stateLabel, systemImage: summary.status == "FAILED" ? "exclamationmark.triangle" : "checkmark.circle")
                        .foregroundStyle(tint)
                    Spacer()
                    Text(String(summary.identifier.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let albumName = summary.albumName, !albumName.isEmpty { Text(albumName).font(.headline) }
                if summary.totalBytes > 0 {
                    ProgressView(value: summary.fraction).tint(.bridgeBlue)
                    HStack { Text("\(summary.completed)/\(summary.total) 项").frame(width: 74, alignment: .leading); Spacer(); Text("\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))") }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else { Text("已保存 \(summary.completed) 项").font(.caption.monospacedDigit()).frame(width: 110, alignment: .leading).foregroundStyle(.secondary) }
                if let elapsed = summary.elapsedSeconds {
                    Text("已用 \(elapsedText(elapsed))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let error = summary.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
        }
    }
    private func elapsedText(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}
