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
                Section(collection.localizedTitle ?? "保存照片") {
                    if let memberCount { Text("将保存 (memberCount) 张照片") }
                    if let freeSpace { Text("手机可用空间：(freeSpace)").foregroundStyle(.secondary) }
                    Text("原图会完整保留，照片顺序也会一起保存。")
                    Toggle("原图只在 iCloud 时允许下载", isOn: $allowNetwork)
                        .disabled(exporter.busy)
                    Button("开始准备照片") {
                        Task { await exporter.start(collection: collection, allowNetwork: allowNetwork) }
                    }
                    .disabled(exporter.busy || memberCount == nil || memberCount == 0)
                    if exporter.busy {
                        ProgressView()
                        Button("完成当前照片后暂停") { exporter.requestStop() }
                    }
                }

                Section("保存进度") {
                    Text(exporter.message)
                        .textSelection(.enabled)
                    if exporter.totalResources > 0 {
                        ProgressView(value: Double(exporter.resourcesCompleted), total: Double(exporter.totalResources))
                        Text("已准备 (exporter.resourcesCompleted)/(exporter.totalResources) 个文件")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("完成后照片会暂存在 iPhone 的 PhotoBridge 文件区。回到 Mac 点“查找手机备份”，再选择保存文件夹。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("继续上次保存") {
                    Button("查找未完成的保存") {
                        Task { await exporter.refreshCandidates(collection: collection) }
                    }
                    .disabled(exporter.busy)
                    if exporter.candidates.isEmpty {
                        Text("没有找到未完成的保存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("选择保存", selection: $resumeSession) {
                            Text("请选择").tag("")
                            ForEach(exporter.candidates) { candidate in
                                Text("保存 (candidate.id.prefix(8))").tag(candidate.id)
                            }
                        }
                        Button("继续保存") {
                            Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: resumeSession) }
                        }
                        .disabled(exporter.busy || resumeSession.isEmpty)
                    }
                }
            }
            .navigationTitle("保存到 Mac")
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
