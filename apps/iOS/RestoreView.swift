import SwiftUI
import Photos
import PhotoBridgeCore

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 恢复 " + String(UUID().uuidString.prefix(8))
    @State private var allowTimestampRewrite = false
    @State private var stopAfterFirstCommit = false
    private var integrityState: (String, Color, String) {
        if service.completed == service.totalAssets, service.totalAssets > 0, service.message.contains("照片库回读完成") {
            return ("可以恢复", .green, "照片文件已检查完整")
        }
        if service.ready { return ("检查通过", .blue, "这份备份可以使用") }
        return ("等待检查", .secondary, "先检查这份备份")
    }
    private var orderState: (String, Color, String) {
        if service.message.contains("成员顺序通过") {
            return ("顺序已保留", .green, "恢复后请在照片中看一眼新相册")
        }
        return ("等待恢复", .secondary, "恢复完成后会创建新的相册")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Mac 备份") {
                    Button("查找 Mac 备份") { service.refresh(); session = service.sessions.last ?? "" }.disabled(service.busy)
                    if service.sessions.isEmpty { Text("还没有找到备份。请先在 Mac 选择“恢复到 iPhone”。") }
                    else {
                        Picker("选择备份", selection: $session) {
                            ForEach(service.sessions, id: \.self) { value in Text(String(value.prefix(8))).tag(value) }
                        }.disabled(service.busy)
                        if !session.isEmpty {
                            Label("已选择备份：\(String(session.prefix(8)))…", systemImage: "externaldrive.connected.to.line.below")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("允许系统重新记录编辑时间", isOn: $allowTimestampRewrite).disabled(service.busy)
                        Text("只影响恢复后的新照片，不会改变原照片。默认关闭。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("检查这份备份") { Task { await service.preflight(session: session, allowTimestampRewrite: allowTimestampRewrite) } }
                            .disabled(service.busy || session.isEmpty)
                    }
                }
                Section(service.recovering ? "继续恢复" : "恢复到新相册") {
                    TextField("新相册名称", text: $title).disabled(service.busy || service.recovering)
                    Text("恢复会添加新的照片和新的相册，不会修改或删除现有内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("高级设置") {
                        Toggle("保存第一张后暂停", isOn: $stopAfterFirstCommit).disabled(service.busy || service.recovering)
                        Button("测试空间不足提示") {
                            Task { await service.preflight(session: session, allowTimestampRewrite: allowTimestampRewrite, simulateNoSpace: true) }
                        }.disabled(service.busy || session.isEmpty)
                        Text("只做提示测试，不会写入照片。测试后需要重新检查备份。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("用于测试暂停后重新打开 App 是否能继续。日常使用不需要打开。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(service.recovering ? "继续恢复" : "开始恢复") {
                        Task { await service.restore(title: title, stopAfterFirstCommit: stopAfterFirstCommit) }
                    }
                        .disabled(!service.ready || service.busy)
                    if service.busy {
                        ProgressView()
                        Button("完成当前照片后暂停") { service.requestStop() }
                    }
                    if service.totalAssets > 0 {
                        ProgressView(value: Double(service.completed), total: Double(service.totalAssets))
                        Text("恢复进度 \(service.completed)/\(service.totalAssets) 张")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Section("恢复结果") {
                    HStack(spacing: 10) {
                        VerificationCard(title: "文件完整性", value: integrityState.0, detail: integrityState.2, tint: integrityState.1)
                        VerificationCard(title: "自建相簿顺序", value: orderState.0, detail: orderState.2, tint: orderState.1)
                    }
                    Text(service.message).textSelection(.enabled)
                    if !service.preflightReportSummary.isEmpty {
                        DisclosureGroup("检查详情") {
                            Text(service.preflightReportSummary).font(.caption).textSelection(.enabled)
                            Button(service.sharedPreflightReport ? "Mac 已读取检查结果" : "把检查结果交给 Mac") {
                                service.sharePreflightReportWithMac()
                            }.disabled(service.busy || service.sharedPreflightReport)
                        }
                    }
                    Text("已检查 \(service.completed) 张").monospacedDigit()
                    if service.authorizedTimestampDifferences > 0 { Text("有 \(service.authorizedTimestampDifferences) 个编辑时间由系统重新记录").foregroundStyle(.secondary) }
                    Text("如果中途停止，已完成的照片会保留，重新打开后可以继续。")
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

private struct VerificationCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: value.contains("通过") ? "checkmark.shield.fill" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
