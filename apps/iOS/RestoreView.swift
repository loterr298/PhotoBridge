import SwiftUI
import PhotoBridgeCore
import ImageIO
import UIKit

struct RestoreView: View {
    @EnvironmentObject private var control: MacControlService
    @StateObject private var service = RestoreService()
    @State private var session = ""
    @State private var title = "PhotoBridge 相册"
    @State private var showOptions = false
    @State private var allowEditedTimeReset = false
    private var finished: Bool { service.verifiedFinished }
    private var working: Bool { service.busy || service.loadingSessions }
    private var friendlyMessage: String {
        if service.message.hasPrefix("正在检查") { return "正在检查照片，请稍候。" }
        if service.message.hasPrefix("正在恢复") { return "正在导入照片。" }
        if service.message.hasPrefix("准备恢复") { return "照片已检查，可以开始导入。" }
        return service.message
    }
    private func refresh() async {
        await service.refresh()
        session = service.sessions.last ?? ""
        if !session.isEmpty { await service.loadPreview(session: session) }
    }
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("导入到 iPhone").font(.largeTitle.bold()).foregroundStyle(Color.bridgeInk)
                            Text("把 Mac 发来的照片，保存到新相册。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        PhoneConnectionStatus(connected: control.connected)
                        if let display = control.macProgress, display.direction == "TO_IPHONE", !service.busy, !finished, (session.isEmpty || display.sessionID == session) {
                            BridgeCard { PhotoCountView(title: display.presentationLabel(), progress: display.progress) }
                        }
                        if finished {
                            BridgeCard {
                                VStack(alignment: .leading, spacing: 16) {
                                    PhotoCountView(title: "导入完成", progress: service.displayProgress)
                                    Text("在系统照片中查看新相册。").font(.subheadline).foregroundStyle(.secondary)
                                    Button("查找其他照片") { Task { await refresh() } }.buttonStyle(BridgeButtonStyle())
                                }
                            }
                        } else {
                            BridgeCard {
                                VStack(alignment: .leading, spacing: 20) {
                                    if service.sessions.isEmpty {
                                        Text("先在 Mac 选择相册文件夹并发送。").foregroundStyle(.secondary)
                                        Button { Task { await refresh() } } label: {
                                            HStack {
                                                if service.loadingSessions { ProgressView() }
                                                Text("查找收到的照片")
                                            }.frame(maxWidth: .infinity)
                                        }.buttonStyle(BridgeButtonStyle(primary: true)).disabled(working)
                                    } else {
                                        Text("收到的相册").font(.headline)
                                        Picker("选择相册", selection: $session) {
                                            ForEach(service.sessions, id: \.self) { value in
                                                Text(service.sessionLabels[value] ?? "收到的相册").tag(value)
                                            }
                                        }.pickerStyle(.menu).disabled(working)
                                        RestoreThumbnailGrid(items: service.previewItems, loading: service.loadingPreview)
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("新相册名称").font(.subheadline).foregroundStyle(.secondary)
                                            TextField("相册名称", text: $title).padding(13)
                                                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                                                .disabled(working)
                                        }
                                        if service.busy {
                                            PhotoCountView(title: service.phase == "CHECKING" ? "正在检查照片" : service.phase == "FINALIZING" ? "正在完成最后检查" : "正在导入相册", progress: service.displayProgress)
                                            Button("暂停并保留进度") { service.requestStop() }.buttonStyle(BridgeButtonStyle())
                                        } else {
                                            Button {
                                                Task {
                                                    if service.ready { await service.restore(title: title, stopAfterFirstCommit: false) }
                                                    else { await service.preflight(session: session, allowTimestampRewrite: allowEditedTimeReset) }
                                                }
                                            } label: {
                                                Text(service.ready ? (service.recovering ? "继续导入" : "开始导入") : "检查照片")
                                                    .frame(maxWidth: .infinity)
                                            }.buttonStyle(BridgeButtonStyle(primary: true)).disabled(session.isEmpty || working)
                                        }
                                        DisclosureGroup("更多选项", isExpanded: $showOptions) {
                                            VStack(alignment: .leading, spacing: 16) {
                                                Button("重新查找收到的照片") { Task { await refresh() } }.buttonStyle(BridgeButtonStyle()).disabled(working)
                                                Toggle("兼容已编辑照片", isOn: $allowEditedTimeReset).disabled(working)
                                                Text("允许系统重置新副本的编辑记录时间。原始附件仍保留，其他信息变化仍会停止导入。")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }.padding(.top, 12)
                                        }.font(.subheadline).tint(.bridgeBlue)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !service.message.isEmpty { Text(friendlyMessage).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                        }
                        Text("保留相册顺序，原照片不会删除。").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: 580, alignment: .leading).frame(maxWidth: .infinity)
                }
            }.navigationBarHidden(true)
        }
        .task { if service.sessions.isEmpty && !service.busy { await refresh() } }
        .onChange(of: service.savedTitle) { value in if !value.isEmpty { title = value } }
        .onChange(of: session) { value in
            service.invalidate()
            Task { await service.loadPreview(session: value) }
        }
        .onChange(of: allowEditedTimeReset) { _ in service.invalidate() }
    }
}

private struct RestoreThumbnailGrid: View {
    let items: [RestorePreviewItem]
    let loading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件夹预览").font(.subheadline.weight(.semibold))
            if loading {
                ProgressView("正在读取缩略图…").frame(maxWidth: .infinity, minHeight: 90)
            } else if items.isEmpty {
                Text("还没有可预览的照片").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(items) { item in RestoreThumbnailCell(item: item) }
                }
                Text("共 \(items.count.formatted()) 张，按文件夹顺序显示").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RestoreThumbnailCell: View {
    let item: RestorePreviewItem
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .tertiarySystemGroupedBackground))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
            Text(String(format: "%04d", item.ordinal)).font(.caption2.monospacedDigit()).foregroundStyle(.white)
                .padding(4).background(.black.opacity(0.48), in: Capsule()).padding(4)
        }
        .frame(height: 74).clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.url) { image = await Self.thumbnail(at: item.url) }
        .accessibilityLabel("第 \(item.ordinal) 张，\(item.filename)")
    }
    private static func thumbnail(at url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}
