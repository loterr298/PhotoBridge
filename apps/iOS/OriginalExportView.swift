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
                Section(collection.localizedTitle ?? "原始资源导出") {
                    if let memberCount { Text("本次将导出 \(memberCount) 个相簿成员的全部可访问资源") }
                    if let freeSpace { Text("本机当前可用空间：\(freeSpace)").foregroundStyle(.secondary) }
                    Text("按当前相簿返回位置导出系统提供的全部资源，包括原图、Live Photo 配对视频和可访问的编辑附件。未知资源类型也保留；尚未验证其导回支持。")
                    Text("只写入 App 新建的暂存目录，不改变原照片、EXIF、GPS、MakerNotes 或拍摄时间。继续时旧会话保留，已完成资源校验后复制；未完成的单个资源从头读取，需为新会话预留空间。请保持 App 前台。")
                    Toggle("允许从 iCloud 下载原件", isOn: $allowNetwork).disabled(exporter.busy)
                    Text("默认离线。开启后可能使用网络下载；失败会保留错误，绝不替换成缩略图。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("开始导出到本机暂存") {
                        Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, stopAfterResources: diagnosticStop ? 1 : nil) }
                    }.disabled(exporter.busy || memberCount == nil || memberCount == 0)
                    if exporter.busy {
                        ProgressView()
                        Button("完成当前资源后停止") { exporter.requestStop() }
                    }
                }
                Section("继续未完成暂存") {
                    Button("刷新未完成会话") {
                        Task { await exporter.refreshCandidates(collection: collection) }
                    }.disabled(exporter.busy)
                    if exporter.candidates.isEmpty {
                        Text("没有可继续的会话。旧版无资源检查点的会话需重新开始，旧文件仍保留。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("来源会话", selection: $resumeSession) {
                            Text("请选择").tag("")
                            ForEach(exporter.candidates) { candidate in
                                Text("\(candidate.id.prefix(8)) · \(candidate.capturedAt.formatted(date: .abbreviated, time: .shortened))").tag(candidate.id)
                            }
                        }.disabled(exporter.busy)
                        Button("校验并继续到新会话") {
                            Task { await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: resumeSession) }
                        }.disabled(exporter.busy || !exporter.candidates.contains(where: { $0.id == resumeSession }))
                    }
                    Text("相簿、顺序、照片编辑或资源目录变化时拒绝继续；全库权限不可用时停止。不会写入或重新导入照片库。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("中断恢复诊断") {
                        Toggle("新导出完成 1 个资源后停止", isOn: $diagnosticStop).disabled(exporter.busy)
                        Text("仅用于复验资源边界停止及重启后继续；继续操作不受此开关影响。不是系统强制终止测试结果。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("真实结果") {
                    Text(exporter.message).textSelection(.enabled)
                    Text("已完成 \(exporter.resourcesCompleted) 个资源 · \(exporter.bytesCompleted) bytes").monospacedDigit()
                    Text("校验复用 \(exporter.reusedResources) 个 · PhotoKit 重新读取 \(exporter.photoKitResourcesRead) 个").monospacedDigit()
                    if let session = exporter.sessionName {
                        Text("Mac 读取路径：Exports/\(session)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Text("Mac 校验后为新副本设置 5 秒间隔的文件系统时间；创建时间按磁盘支持情况验证并记录，不改媒体内部时间。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("原始资源导出")
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
