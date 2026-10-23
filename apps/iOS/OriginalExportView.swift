import SwiftUI
import Photos

struct OriginalExportView: View {
    let collection: PHAssetCollection
    @StateObject private var exporter = OriginalExportService()
    @State private var allowNetwork = false
    @State private var memberCount: Int?
    @State private var freeSpace: String?
    @State private var resumeSession = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(collection.localizedTitle ?? "选择的相册") {
                    if let memberCount { Text("将保存 \(memberCount) 张照片") }
                    if let freeSpace { Text("手机可用空间：\(freeSpace)").foregroundStyle(.secondary) }
                    Text("照片顺序和画质会保留。")
                    Toggle("需要时从 iCloud 下载原图", isOn: $allowNetwork)
                        .disabled(exporter.busy)
                    Button("开始备份到 Mac") {
                        Task { await exporter.start(collection: collection, allowNetwork: allowNetwork) }
                    }
                    .disabled(exporter.busy || memberCount == nil || memberCount == 0)
                    if exporter.busy {
                        ProgressView()
                        Button("完成当前照片后暂停") { exporter.requestStop() }
                    }
                }

                Section("备份进度") {
                    Text(exporter.message)
                        .textSelection(.enabled)
                    if exporter.totalResources > 0 {
                        ProgressView(value: Double(exporter.resourcesCompleted), total: Double(exporter.totalResources))
                        Text("已备份 \(exporter.resourcesCompleted)/\(exporter.totalResources) 个文件")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("手机准备完成后，回到 Mac 点“查找手机备份”，再选择保存文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("继续上次备份") {
                    Button("查找未完成的备份") {
                        Task { await exporter.refreshCandidates(collection: collection) }
                    }
                    .disabled(exporter.busy)
                    if exporter.candidates.isEmpty {
                        Text("没有找到未完成的备份。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("选择保存", selection: $resumeSession) {
                            Text("请选择").tag("")
                            ForEach(exporter.candidates) { candidate in
                                Text("未完成备份 \(candidate.id.prefix(8))").tag(candidate.id)
                            }
                        }
                        Button("继续备份") {
                            Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: resumeSession) }
                        }
                        .disabled(exporter.busy || resumeSession.isEmpty)
                    }
                }
            }
            .navigationTitle("备份到 Mac")
        }
        .task {
            memberCount = PHAsset.fetchAssets(in: collection, options: nil).count
            await exporter.refreshCandidates(collection: collection)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: docs.path),
               let available = attributes[.systemFreeSize] as? NSNumber {
                freeSpace = ByteCountFormatter.string(fromByteCount: available.int64Value, countStyle: .file)
            }
        }
        .onDisappear { exporter.requestStop() }
    }
}
