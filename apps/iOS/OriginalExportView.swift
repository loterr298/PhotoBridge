import SwiftUI
import Photos

/// 用户从相册进入的单一任务页：选择好相册后，只需要点击一次开始备份。
struct OriginalExportView: View {
    let collection: PHAssetCollection
    @StateObject private var exporter = OriginalExportService()
    @State private var allowNetwork = false
    @State private var memberCount: Int?
    @State private var freeSpace: String?
    @State private var hasStarted = false

    private var albumName: String { collection.localizedTitle ?? "我的相册" }
    private var friendlyMessage: String {
        let value = exporter.message
        if value == "尚未导出" { return "还没有开始备份" }
        if value.hasPrefix("正在准备") { return "正在准备照片…" }
        if value.hasPrefix("正在保存") { return "正在备份照片…" }
        if value.hasPrefix("正在整理") { return "正在整理备份…" }
        if value.hasPrefix("保存完成") { return "照片已准备好，请回到 Mac 选择保存位置" }
        return value
    }

    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        pageHeader
                        backupCard
                        progressSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("备份到 Mac")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task(loadAlbumInfo)
        .onDisappear { exporter.requestStop() }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("备份到 Mac")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.bridgeInk)
            Text(albumName)
                .font(.subheadline)
                .foregroundStyle(Color.bridgeMuted)
        }
    }

    private var backupCard: some View {
        BridgeCard {
            VStack(alignment: .leading, spacing: 0) {
                infoRow {
                    Text(memberCount.map { "将保存 \($0.formatted()) 张照片" } ?? "正在读取照片数量…")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.bridgeInk)
                }
                divider
                infoRow {
                    Text("手机可用空间")
                    Spacer()
                    Text(freeSpace ?? "正在检查…")
                        .foregroundStyle(Color.bridgeMuted)
                }
                divider
                infoRow {
                    Label("照片顺序和画质会保留", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.bridgeInk)
                }
                divider
                Toggle("需要时下载原图", isOn: $allowNetwork)
                    .font(.subheadline)
                    .tint(.bridgeBlue)
                    .disabled(exporter.busy)
                    .padding(.vertical, 15)
                divider
                Button {
                    hasStarted = true
                    Task { await exporter.start(collection: collection, allowNetwork: allowNetwork) }
                } label: {
                    HStack {
                        Text(exporter.busy ? "正在备份…" : "开始备份到 Mac")
                        Spacer()
                        Image(systemName: exporter.busy ? "arrow.triangle.2.circlepath" : "arrow.down.to.line.compact")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.bridgeBlue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 15)
                }
                .disabled(exporter.busy || memberCount == nil || memberCount == 0)
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("备份进度")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bridgeMuted)

            BridgeCard {
                VStack(alignment: .leading, spacing: 13) {
                    if exporter.scanning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取 \(memberCount ?? 0) 张照片…")
                        }
                    } else if exporter.totalResources > 0 && exporter.busy {
                        ProgressView(value: Double(exporter.resourcesCompleted), total: Double(exporter.totalResources))
                            .tint(.bridgeBlue)
                        Text("已备份 \(exporter.resourcesCompleted)/\(exporter.totalResources) 个文件")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.bridgeMuted)
                    } else {
                        Text(hasStarted ? friendlyMessage : "还没有开始备份")
                            .font(.body)
                            .foregroundStyle(Color.bridgeInk)
                    }

                    if !exporter.message.isEmpty && exporter.message != "尚未导出" && !exporter.scanning {
                        Text(friendlyMessage)
                            .font(.caption)
                            .foregroundStyle(Color.bridgeMuted)
                            .lineLimit(2)
                    }

                    if exporter.busy {
                        Button("暂停备份") { exporter.requestStop() }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.bridgeBlue)
                    } else if exporter.message.hasPrefix("保存完成") {
                        Label("回到 Mac，选择保存文件夹即可完成备份", systemImage: "arrow.right.circle")
                            .font(.caption)
                            .foregroundStyle(Color.bridgeMuted)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, content: content)
            .padding(.vertical, 15)
    }

    private var divider: some View { Divider().overlay(Color.black.opacity(0.08)) }

    private func loadAlbumInfo() async {
        let identifier = collection.localIdentifier
        memberCount = await Task.detached(priority: .utility) {
            guard let current = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else { return 0 }
            return PHAsset.fetchAssets(in: current, options: nil).count
        }.value

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: documents.path),
           let available = attributes[.systemFreeSize] as? NSNumber {
            freeSpace = ByteCountFormatter.string(fromByteCount: available.int64Value, countStyle: .file)
        }
    }
}
