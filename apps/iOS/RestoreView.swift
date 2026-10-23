import SwiftUI

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 相册"
    @State private var allowTimestampRewrite = false
    private var finished: Bool { service.totalAssets > 0 && service.completed == service.totalAssets && service.message.hasPrefix("恢复完成") }
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("恢复").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                            Text("把 Mac 上的照片按原相册顺序带回 iPhone").foregroundStyle(.secondary)
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    BridgeIconCircle(systemImage: "arrow.down.to.line.compact", tint: .bridgeBlue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("选择一份 Mac 保存").font(.headline)
                                        Text("照片会进入一个新的相册，不会改动原相册").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Button("查找 Mac 保存") { service.refresh(); session = service.sessions.last ?? "" }
                                    .buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                                if service.sessions.isEmpty {
                                    Text("还没有找到保存。请先在 Mac 选择文件夹并发送到 iPhone。").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Picker("选择保存", selection: $session) {
                                        ForEach(service.sessions, id: \.self) { value in Text("保存 \(value.prefix(8))").tag(value) }
                                    }
                                    Button("检查这份保存") { Task { await service.preflight(session: session, allowTimestampRewrite: allowTimestampRewrite) } }
                                        .buttonStyle(.bordered).controlSize(.large).disabled(service.busy || session.isEmpty)
                                }
                            }
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("恢复到新相册").font(.headline)
                                TextField("新相册名称", text: $title).textFieldStyle(.roundedBorder).disabled(service.busy)
                                Button(service.recovering ? "继续恢复" : "开始恢复") { Task { await service.restore(title: title, stopAfterFirstCommit: false) } }
                                    .buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                                    .disabled(!service.ready || service.busy)
                                if service.busy {
                                    ProgressView(value: service.totalAssets > 0 ? Double(service.completed) / Double(service.totalAssets) : nil).tint(.bridgeBlue)
                                    HStack { Text("正在恢复"); Spacer(); Text("\(service.completed)/\(service.totalAssets)") }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Button("暂停并保留进度") { service.requestStop() }.buttonStyle(.bordered)
                                }
                            }
                        }
                        if finished {
                            HStack(spacing: 12) {
                                BridgeIconCircle(systemImage: "checkmark.circle.fill", tint: .green, size: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("恢复完成").font(.headline)
                                    Text("请在系统照片中查看新相册和顺序").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 4)
                        } else if !service.message.isEmpty {
                            Text(service.message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        DisclosureGroup("更多选项") {
                            Toggle("允许系统重新记录编辑时间", isOn: $allowTimestampRewrite)
                            Text("默认关闭，只影响恢复后的新照片。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
        .task { service.refresh(); session = service.sessions.last ?? "" }
        .onChange(of: service.savedTitle) { value in if !value.isEmpty { title = value } }
        .onChange(of: session) { _ in service.invalidate() }
        .onChange(of: allowTimestampRewrite) { _ in service.invalidate() }
        .onDisappear { service.requestStop() }
    }
}
