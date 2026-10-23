import SwiftUI

struct RestoreView: View {
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 相册"
        private var finished: Bool { service.totalAssets > 0 && service.completed == service.totalAssets && service.message.hasPrefix("恢复完成") }
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("导入到 iPhone").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                            Text("选择 Mac 上的照片，按原相册顺序导入").foregroundStyle(.secondary)
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    BridgeIconCircle(systemImage: "arrow.down.to.line.compact", tint: .bridgeBlue)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("选择 Mac 照片").font(.headline)
                                        Text("会创建一个新相册，不会改动原相册").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Button("查找 Mac 照片") { service.refresh(); session = service.sessions.last ?? "" }
                                    .buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                                if service.sessions.isEmpty {
                                    Text("还没有找到照片。请先在 Mac 选择文件夹并发送。").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Picker("选择照片", selection: $session) {
                                        ForEach(service.sessions, id: \.self) { value in Text("保存 \(value.prefix(8))").tag(value) }
                                    }
                                    Button("检查照片") { Task { await service.preflight(session: session, allowTimestampRewrite: false) } }
                                        .buttonStyle(.bordered).controlSize(.large).disabled(service.busy || session.isEmpty)
                                }
                            }
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("导入到新相册").font(.headline)
                                TextField("新相册名称", text: $title).textFieldStyle(.roundedBorder).disabled(service.busy)
                                Button(service.recovering ? "继续导入" : "开始导入") { Task { await service.restore(title: title, stopAfterFirstCommit: false) } }
                                    .buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                                    .disabled(!service.ready || service.busy)
                                if service.busy {
                                    ProgressView(value: service.totalAssets > 0 ? Double(service.completed) / Double(service.totalAssets) : nil).tint(.bridgeBlue)
                                    HStack { Text("正在导入"); Spacer(); Text("\(service.completed)/\(service.totalAssets)") }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Button("暂停并保留进度") { service.requestStop() }.buttonStyle(.bordered)
                                }
                            }
                        }
                        if finished {
                            HStack(spacing: 12) {
                                BridgeIconCircle(systemImage: "checkmark.circle.fill", tint: .green, size: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("导入完成").font(.headline)
                                    Text("完成后可在系统照片中查看新相册").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 4)
                        } else if !service.message.isEmpty {
                            Text(service.message).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
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
                .onDisappear { service.requestStop() }
    }
}
