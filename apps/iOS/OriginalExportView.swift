import SwiftUI
import Photos

/// A calm, single-purpose task screen for saving one iPhone album to the Mac.
struct OriginalExportView: View {
    let collection: PHAssetCollection
    @StateObject private var exporter = OriginalExportService()
    @State private var allowNetwork = false
    @State private var memberCount: Int?
    @State private var freeSpace: String?
    @State private var coverAsset: PHAsset?
    @State private var hasStarted = false
    @State private var showMoreOptions = false

    private var albumName: String { collection.localizedTitle ?? "我的相册" }
    private var isFinished: Bool { !exporter.busy && exporter.message.hasPrefix("保存完成") }

    var body: some View {
        ZStack {
            Color.bridgeSky.opacity(0.38).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    titleBlock
                    albumPreview
                    actionBlock
                    progressBlock
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(loadAlbumInfo)
        .onDisappear { exporter.requestStop() }
    }

    private var titleBlock: some View {
        VStack(spacing: 7) {
            Text("备份到 Mac")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(Color.bridgeInk)
            Text("把“\(albumName)”保存到 Mac")
                .font(.body)
                .foregroundStyle(Color.bridgeMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var albumPreview: some View {
        VStack(spacing: 15) {
            AssetThumbnail(asset: coverAsset)
                .frame(width: 108, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.8), lineWidth: 1))

            VStack(spacing: 5) {
                Text(albumName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.bridgeInk)
                Text(memberCount.map { "\($0.formatted()) 张照片" } ?? "正在读取照片数量…")
                    .font(.subheadline)
                    .foregroundStyle(Color.bridgeMuted)
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("按原顺序保存，照片质量不变")
                    .font(.caption)
                    .foregroundStyle(Color.bridgeMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: .blue.opacity(0.08), radius: 22, y: 10)
    }

    private var actionBlock: some View {
        VStack(spacing: 12) {
            Button {
                hasStarted = true
                Task { await exporter.start(collection: collection, allowNetwork: allowNetwork) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: exporter.busy ? "arrow.triangle.2.circlepath" : "arrow.down.to.line.compact")
                    Text(exporter.busy ? "正在备份…" : "开始备份到 Mac")
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.bridgeBlue, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.bridgeBlue.opacity(0.25), radius: 14, y: 7)
            }
            .disabled(exporter.busy || memberCount == nil || memberCount == 0)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { showMoreOptions.toggle() }
            } label: {
                HStack {
                    Text("更多选项")
                    Spacer()
                    Image(systemName: showMoreOptions ? "chevron.up" : "chevron.down")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bridgeMuted)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)

            if showMoreOptions {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("照片未在手机上时，从 iCloud 获取", isOn: $allowNetwork)
                        .font(.subheadline)
                        .tint(.bridgeBlue)
                        .disabled(exporter.busy)
                    if let freeSpace {
                        Text("手机可用空间：\(freeSpace)")
                            .font(.caption)
                            .foregroundStyle(Color.bridgeMuted)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var progressBlock: some View {
        VStack(spacing: 12) {
            if exporter.scanning {
                statusCard(icon: "photo.stack", title: "正在准备照片", detail: "正在读取相册，请稍候…", showsSpinner: true)
            } else if exporter.busy && exporter.totalResources > 0 {
                let progress = Double(exporter.resourcesCompleted) / Double(exporter.totalResources)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("正在备份")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(progress * 100))%")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Color.bridgeBlue)
                    }
                    ProgressView(value: progress)
                        .tint(.bridgeBlue)
                    Text("已保存 \(exporter.resourcesCompleted) / \(exporter.totalResources) 个文件")
                        .font(.caption)
                        .foregroundStyle(Color.bridgeMuted)
                    Button("暂停备份") { exporter.requestStop() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.bridgeBlue)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else if isFinished {
                statusCard(icon: "checkmark.circle.fill", title: "照片已准备好", detail: "回到 Mac，选择保存文件夹即可完成备份", showsSpinner: false)
            } else if hasStarted {
                statusCard(icon: "exclamationmark.circle", title: "备份没有完成", detail: "已保留当前进度，可以稍后再试", showsSpinner: false)
            }
        }
    }

    private func statusCard(icon: String, title: String, detail: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 14) {
            if showsSpinner {
                ProgressView()
                    .tint(.bridgeBlue)
                    .frame(width: 46, height: 46)
                    .background(Color.bridgeBlue.opacity(0.12), in: Circle())
            } else {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isFinished ? .green : Color.bridgeBlue)
                    .frame(width: 46, height: 46)
                    .background(Color.bridgeBlue.opacity(0.12), in: Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(Color.bridgeInk)
                Text(detail).font(.caption).foregroundStyle(Color.bridgeMuted)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func loadAlbumInfo() async {
        let identifier = collection.localIdentifier
        let info = await Task.detached(priority: .utility) {
            guard let current = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else { return (count: 0, coverID: Optional<String>.none) }
            let assets = PHAsset.fetchAssets(in: current, options: nil)
            return (count: assets.count, coverID: assets.firstObject?.localIdentifier)
        }.value
        memberCount = info.count
        if let coverID = info.coverID {
            coverAsset = PHAsset.fetchAssets(withLocalIdentifiers: [coverID], options: nil).firstObject
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: documents.path),
           let available = attributes[.systemFreeSize] as? NSNumber {
            freeSpace = ByteCountFormatter.string(fromByteCount: available.int64Value, countStyle: .file)
        }
    }
}
