import SwiftUI
import Photos
import PhotoBridgeCore

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 恢复 " + String(UUID().uuidString.prefix(8))
    @State private var allowTimestampRewrite = false
    @State private var stopAfterFirstCommit = false
    var body: some View {
        NavigationStack {
            Form {
                Section("USB 备份收件箱") {
                    Button("刷新收件箱") { service.refresh(); session = service.sessions.last ?? "" }.disabled(service.busy)
                    if service.sessions.isEmpty { Text("没有完整收件。请在 Mac 使用 album_restore.py 发送已校验备份。") }
                    else {
                        Picker("恢复会话", selection: $session) {
                            ForEach(service.sessions, id: \.self) { value in Text(String(value.prefix(8))).tag(value) }
                        }.disabled(service.busy)
                        Toggle("允许新副本的系统编辑记录时间重置", isOn: $allowTimestampRewrite).disabled(service.busy)
                        Text("默认关闭。开启仅接受编辑附件 adjustmentTimestamp 变化；原图、编辑后图像及其他字段仍严格校验，原始附件保留，并报告附件 hash 差异。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("校验收件与 PhotoKit 支持") { Task { await service.preflight(session: session, allowTimestampRewrite: allowTimestampRewrite) } }
                            .disabled(service.busy || session.isEmpty)
                    }
                }
                Section(service.recovering ? "继续已记录会话" : "创建新相簿") {
                    TextField("新相簿名", text: $title).disabled(service.busy || service.recovering)
                    Text("完整资源预检通过后才能写入。此操作会向照片库添加副本并创建新相簿；不修改现有相簿，不移动或删除收件文件。使用清单原拍摄日期，不把 Mac 的 5 秒辅助时间写入照片库。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("中断恢复诊断") {
                        Toggle("首个 Photos 事务完成后停止", isOn: $stopAfterFirstCommit).disabled(service.busy || service.recovering)
                        Text("仅用于新会话：提交首个副本并保存标识后、回读资源前停止。重启后重新预检同一会话继续；这不等于事务提交中被强制终止测试。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(service.recovering ? "回读已有副本并继续剩余资源" : "创建新相簿并导入全部资源") {
                        Task { await service.restore(title: title, stopAfterFirstCommit: stopAfterFirstCommit) }
                    }
                        .disabled(!service.ready || service.busy)
                    if service.busy {
                        ProgressView()
                        Button("完成当前事务后停止") { service.requestStop() }
                    }
                }
                Section("真实结果") {
                    Text(service.message).textSelection(.enabled)
                    Text("已回读校验 \(service.completed) 项").monospacedDigit()
                    if service.authorizedTimestampDifferences > 0 { Text("\(service.authorizedTimestampDifferences) 份附件存在已授权的系统编辑时间变化，附件非字节一致").foregroundStyle(.secondary) }
                    Text("新版仅按已保存的副本标识恢复；先回读已有资源再继续。旧版失败会话、缺失标识或对象不可见时均拒绝重放。每次校验保留独立日志和资源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("恢复")
        }.task { service.refresh(); session = service.sessions.last ?? "" }
            .onChange(of: service.savedTitle) { value in if !value.isEmpty { title = value } }
            .onChange(of: session) { _ in service.invalidate() }
            .onChange(of: allowTimestampRewrite) { _ in service.invalidate() }
            .onDisappear { service.requestStop() }
    }
}
