import SwiftUI

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 相册"
    @State private var allowTimestampRewrite = false
    private var finished: Bool {
        service.totalAssets > 0 && service.completed == service.totalAssets && service.message.hasPrefix("恢复完成")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("选择 Mac 备份") {
                    Button("查找备份") {
                        service.refresh()
                        session = service.sessions.last ?? ""
                    }
                    .disabled(service.busy)
                    if service.sessions.isEmpty {
                        Text("请先在 Mac 选择文件夹并发送到 iPhone。")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("备份", selection: $session) {
                            ForEach(service.sessions, id: \.self) { value in
                                Text(String(value.prefix(8))).tag(value)
                            }
                        }
                        Button("检查备份") {
                            Task { await service.preflight(session: session, allowTimestampRewrite: allowTimestampRewrite) }
                        }
                        .disabled(service.busy || session.isEmpty)
                    }
                }

                Section("恢复到新相册") {
                    TextField("新相册名称", text: $title)
                        .disabled(service.busy)
                    Text("会创建新的照片和新的相册，不会改动手机里已有的内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(service.recovering ? "继续恢复" : "开始恢复") {
                        Task { await service.restore(title: title, stopAfterFirstCommit: false) }
                    }
                    .disabled(!service.ready || service.busy)
                    if service.busy {
                        ProgressView()
                        Button("完成当前照片后暂停") { service.requestStop() }
                    }
                    if service.totalAssets > 0 {
                        ProgressView(value: Double(service.completed), total: Double(service.totalAssets))
                        Text("已恢复 (service.completed)/(service.totalAssets) 张")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("更多选项") {
                    Toggle("允许系统重新记录编辑时间", isOn: $allowTimestampRewrite)
                    Text("只影响恢复后的新照片，原照片不会改变。默认关闭。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("结果") {
                    HStack(spacing: 10) {
                        VerificationCard(title: "文件完整性", value: finished ? "已完成" : (service.ready ? "检查通过" : "等待检查"), detail: finished ? "照片文件已检查完整" : "先检查这份备份", tint: finished ? .green : (service.ready ? .blue : .secondary))
                        VerificationCard(title: "相册顺序", value: finished ? "顺序已恢复" : "等待恢复", detail: finished ? "请在照片中看一眼新相册" : "恢复完成后会创建新相册", tint: finished ? .green : .secondary)
                    }
                    Text(service.message)
                        .textSelection(.enabled)
                    if service.authorizedTimestampDifferences > 0 {
                        Text("系统重新记录了 (service.authorizedTimestampDifferences) 个编辑时间")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("恢复到 iPhone")
        }
        .task { service.refresh(); session = service.sessions.last ?? "" }
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
            Label(title, systemImage: (value == "已完成" || value == "顺序已恢复" || value == "检查通过") ? "checkmark.shield.fill" : "clock")
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
