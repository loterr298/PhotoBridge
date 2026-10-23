import SwiftUI
import Photos
import PhotoBridgeCore

struct OriginalExportView: View {
    let collection: PHAssetCollection
    @StateObject private var exporter = OriginalExportService()
    @State private var allowNetwork = false
    @State private var memberCount: Int?
    @State private var freeSpace: String?
    @State private var resumeSession = ""
    @State private var diagnosticStop = false
    var body: some View {
        NavigationStack {
            Form {
                Section(collection.localizedTitle ?? "保存照片") {
                    if let memberCount { Text("将保存 \(memberCount) 张照片") }
                    if let freeSpace { Text("本机当前可用空间：\(freeSpace)").foregroundStyle(.secondary) }
                    Text("会完整保存原图、Live Photo 和照片里的配套文件，不压缩、不改变原照片。")
                    Text("保存过程中请保持 App 打开。暂停或中断后，已完成的进度会保留。")
                    Toggle("需要时下载云端原图", isOn: $allowNetwork).disabled(exporter.busy)
                    Text("默认不使用网络。打开后，如果原图只在云端，App 会尝试下载完整文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("开始保存") {
                        Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, stopAfterResources: diagnosticStop ? 1 : nil) }
                    }.disabled(exporter.busy || memberCount == nil || memberCount == 0)
                    if exporter.busy {
                        ProgressView()
                        Button("完成当前照片后暂停") { exporter.requestStop() }
                    }
                }
                Section("继续上次进度") {
                    Button("查找未完成的备份") {
                        Task { await exporter.refreshCandidates(collection: collection) }
                    }.disabled(exporter.busy)
                    if exporter.candidates.isEmpty {
                        Text("没有找到可以继续的备份。你可以重新开始，之前的文件不会被删除。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("选择备份", selection: $resumeSession) {
                            Text("请选择").tag("")
                            ForEach(exporter.candidates) { candidate in
                                Text("\(candidate.id.prefix(8)) · \(candidate.capturedAt.formatted(date: .abbreviated, time: .shortened))").tag(candidate.id)
                            }
                        }.disabled(exporter.busy)
                        Button("检查后继续") {
                            Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: resumeSession) }
                        }.disabled(exporter.busy || !exporter.candidates.contains(where: { $0.id == resumeSession }))
                    }
                    Text("如果照片或相册发生变化，App 会停止并提醒你，不会把新旧内容混在一起。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("高级设置") {
                        Toggle("保存 1 张后自动暂停", isOn: $diagnosticStop).disabled(exporter.busy)
                        Text("用于测试暂停后继续。日常使用不需要打开。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("进度") {
                    Text(exporter.message).textSelection(.enabled)
                    Text("已保存 \(exporter.resourcesCompleted) 项 · \(ByteCountFormatter.string(fromByteCount: Int64(exporter.bytesCompleted), countStyle: .file))").monospacedDigit()
                    if exporter.totalResources > 0 {
                        ProgressView(value: Double(exporter.resourcesCompleted), total: Double(exporter.totalResources))
                        Text("进度 \(exporter.resourcesCompleted)/\(exporter.totalResources)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("已检查 \(exporter.resourcesCompleted) 项").monospacedDigit()
                    if let session = exporter.sessionName {
                        Text("备份编号：\(session.prefix(8))").font(.caption).textSelection(.enabled)
                    }
                    Text("Mac 会按相册顺序整理文件，不改变照片里的拍摄时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("保存照片")
        }.task {
            memberCount = PHAsset.fetchAssets(in: collection, options: nil).count
            await exporter.refreshCandidates(collection: collection)
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: docs.path),
               let available = attributes[.systemFreeSize] as? NSNumber {
                freeSpace = ByteCountFormatter.string(fromByteCount: available.int64Value, countStyle: .file)
            }
        }.onDisappear { exporter.requestStop() }
    }
}
