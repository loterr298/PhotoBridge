import SwiftUI
import PhotoBridgeCore

struct RestoreView: View {
    @EnvironmentObject private var control: MacControlService
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 相册"
    private var finished: Bool { service.verifiedFinished }
    private var friendlyMessage: String {
        let value = service.message
        if value.hasPrefix("正在检查") { return "正在检查照片…" }
        if value.hasPrefix("正在恢复") { return "正在导入照片…" }
        if value.hasPrefix("准备恢复") { return "照片已检查，可以开始导入" }
        if value.hasPrefix("恢复完成") { return "导入完成" }
        return value
    }
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
                        if let display = control.macProgress, display.direction == "TO_IPHONE", !service.busy, !finished, (session.isEmpty || display.sessionID == session) {
                            BridgeCard { PhotoCountView(title: display.presentationLabel(), progress: display.progress) }
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
                                Button("查找 Mac 照片") { service.refresh(); session = service.sessions.last ?? "" }.disabled(service.busy)
                                    .buttonStyle(.borderedProminent).tint(.bridgeBlue).controlSize(.large)
                                if service.sessions.isEmpty {
                                    Text("还没有找到照片。请先在 Mac 选择文件夹并发送。").font(.subheadline).foregroundStyle(.secondary)
                                } else {
                                    Picker("选择照片", selection: $session) {
                                        ForEach(service.sessions, id: \.self) { value in Text("保存 \(value.prefix(8))").tag(value) }
                                    }.disabled(service.busy)
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
                                    PhotoCountView(title: service.phase == "CHECKING" ? "正在检查照片" : service.phase == "FINALIZING" ? "正在完成最后检查" : "正在导入到相册", progress: service.displayProgress)
                                    Button("暂停并保留进度") { service.requestStop() }.buttonStyle(.bordered)
                                }
                            }
                        }
                        if finished {
                            HStack(spacing: 12) {
                                BridgeIconCircle(systemImage: "checkmark.circle.fill", tint: .green, size: 48)
                                VStack(alignment: .leading, spacing: 4) {
                                    PhotoCountView(title: "导入完成", progress: service.displayProgress)
                                    Text("完成后可在系统照片中查看新相册").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 4)
                        } else if !service.message.isEmpty {
                            Text(friendlyMessage).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
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
