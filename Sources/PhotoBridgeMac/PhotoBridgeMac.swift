import AppKit
import Foundation
import ImageCaptureCore
import SwiftUI

struct BackupAssetPreview: Identifiable {
    let id: Int
    let ordinal: Int
    let resourceCount: Int
    let byteCount: Int64
    let primaryFilename: String
}

final class CameraDiscovery: NSObject, ObservableObject, ICDeviceBrowserDelegate {
    @Published var devices: [ICDevice] = []
    private let browser = ICDeviceBrowser()

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() { browser.start() }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if !devices.contains(where: { $0 === device }) { devices.append(device) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
    }
}

@MainActor
final class MacTransferModel: ObservableObject {
    @Published var usbState = "等待连接"
    @Published var userMessage = "用数据线连接 iPhone，然后点“检查连接”。"
    @Published var output = "用数据线连接 iPhone，解锁并点“信任”，然后检查连接。"
    @Published var sessions: [String] = []
    @Published var selectedSession = ""
    @Published var busy = false
    @Published var progressFraction = 0.0
    @Published var progressText = ""
    @Published var speedText = ""
    @Published var etaText = ""
    @Published var currentResource = ""
    @Published var recentBackups: [String] = []
    @Published var backupPreview: [BackupAssetPreview] = []

    private let bundleIdentifier = "com.photobridge.OrderProbe"
    private var progressTask: Task<Void, Never>?
    private var controlFile: URL?

    init() {
        recentBackups = UserDefaults.standard.stringArray(forKey: "PhotoBridge.recentBackups") ?? []
    }

    func discover() {
        runScript("usb_probe.py", arguments: ["discover", "--bundle", bundleIdentifier]) { [weak self] result in
            self?.usbState = result.success ? "已连接" : "未连接"
            self?.userMessage = result.success ? "iPhone 已连接，可以开始保存。" : "还没有连接 iPhone，请检查数据线和信任设置。"
            self?.output = result.text
        }
    }

    func refreshSessions() {
        runScript("album_export.py", arguments: ["list", "--bundle", bundleIdentifier]) { [weak self] result in
            self?.output = result.text
            guard result.success,
                  let data = result.text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = json["sessions"] as? [String] else {
                self?.sessions = []
                self?.selectedSession = ""
                self?.userMessage = "还没有找到手机里的保存。请先在 iPhone 选择相册并开始准备。"
                return
            }
            self?.sessions = values
            self?.selectedSession = values.first ?? ""
            self?.userMessage = values.isEmpty ? "还没有找到手机里的保存。" : "已找到 \(values.count) 份手机保存。"
        }
    }

    func downloadSelected() {
        guard !selectedSession.isEmpty else { output = "请先查找并选择一份手机备份。"; return }
        guard let parent = chooseDirectory(title: "选择照片保存位置") else { return }
        let folder = parent.appendingPathComponent("PhotoBridge-\(String(selectedSession.prefix(8)))", isDirectory: true)
        rememberBackup(folder)
        userMessage = "正在把照片保存到你选择的文件夹…"
        runScript("album_export.py", arguments: ["download", "--remote", "Exports/\(selectedSession)", "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "已保存到：\(folder.path)" : "保存没有完成，请重新连接 iPhone 后继续。"
            if result.success { self?.loadPreview(from: folder) }
        }
    }

    func resumeSelected() {
        guard !selectedSession.isEmpty else { output = "请先查找并选择一份手机备份。"; return }
        guard let previous = chooseDirectory(title: "选择上次未完成的备份") else { return }
        guard let parent = chooseDirectory(title: "选择继续保存的位置") else { return }
        let folder = parent.appendingPathComponent("PhotoBridge-resume-\(String(selectedSession.prefix(8)))", isDirectory: true)
        rememberBackup(folder)
        userMessage = "正在继续保存…"
        runScript("album_resume.py", arguments: ["--remote", "Exports/\(selectedSession)", "--from-directory", previous.path, "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "已保存到：\(folder.path)" : "继续保存没有完成，请重试。"
            if result.success { self?.loadPreview(from: folder) }
        }
    }

    func uploadBackup() {
        guard let directory = chooseDirectory(title: "选择要发送到 iPhone 的照片") else { return }
        userMessage = "正在发送照片到 iPhone…"
        runScript("album_restore.py", arguments: ["--local", directory.path, "--bundle", bundleIdentifier], progressDirectory: directory.appendingPathComponent("restore-uploads", isDirectory: true), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "发送没有完成，请重新连接 iPhone 后重试。"
        }
    }

    func resumeUpload() {
        guard let directory = chooseDirectory(title: "选择上次未完成的照片") else { return }
        let journalDirectory = directory.appendingPathComponent("restore-uploads", isDirectory: true)
        guard let journals = try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: [.contentModificationDateKey]),
              let journal = journals.filter({ $0.pathExtension == "json" }).max(by: {
                  let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  return lhs < rhs
              }) else {
            output = "找不到可以继续的备份，请先选择一份已保存的照片。"
            userMessage = output
            return
        }
        userMessage = "正在继续发送照片到 iPhone…"
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--resume-journal", journal.path], progressDirectory: journalDirectory, controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "继续发送没有完成，请重试。"
        }
    }

    func requestCancel() {
        guard let controlFile else { return }
        FileManager.default.createFile(atPath: controlFile.path, contents: Data("safe-stop".utf8))
        output = "已请求暂停，当前照片完成后会停下，已有进度会保留。"
    }

    private func makeControlFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBridge-cancel-\(UUID().uuidString)")
    }

    private func rememberBackup(_ url: URL) {
        recentBackups.removeAll { $0 == url.path }
        recentBackups.insert(url.path, at: 0)
        recentBackups = Array(recentBackups.prefix(8))
        UserDefaults.standard.set(recentBackups, forKey: "PhotoBridge.recentBackups")
    }

    private func loadPreview(from folder: URL) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("album-order.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]] else {
            backupPreview = []
            return
        }
        backupPreview = assets.enumerated().map { index, asset in
            let resources = asset["resources"] as? [[String: Any]] ?? []
            let bytes = resources.compactMap { ($0["byteCount"] as? NSNumber)?.int64Value }.reduce(0, +)
            let name = (resources.first?["originalFilename"] as? String) ?? "原始资源"
            return BackupAssetPreview(id: index, ordinal: index + 1, resourceCount: resources.count, byteCount: bytes, primaryFilename: name)
        }
    }

    private func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private struct ScriptResult {
        let success: Bool
        let text: String
    }

    private func runScript(_ name: String, arguments: [String], progressFile: URL? = nil,
                           progressDirectory: URL? = nil, controlFile: URL? = nil,
                           completion: @escaping (ScriptResult) -> Void) {
        guard !busy else { return }
        busy = true
        self.controlFile = controlFile
        if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
        progressFraction = 0
        progressText = "等待首个进度记录…"
        speedText = ""
        etaText = ""
        currentResource = ""
        startProgressPolling(file: progressFile, directory: progressDirectory)
        output = "正在执行 \(name)…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> ScriptResult in
                do {
                    var commandArguments = arguments
                    if let controlFile { commandArguments += ["--cancel-file", controlFile.path] }
                    return try Self.executeScript(name, arguments: commandArguments)
                } catch {
                    return ScriptResult(success: false, text: "未完成：\(error.localizedDescription)")
                }
            }.value
            progressTask?.cancel()
            if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
            self.controlFile = nil
            busy = false
            completion(result)
        }
    }

    private func startProgressPolling(file: URL?, directory: URL?) {
        progressTask?.cancel()
        guard file != nil || directory != nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                let source = file ?? self.latestProgressFile(in: directory!)
                if let source, let data = try? Data(contentsOf: source),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.applyProgress(json)
                }
            }
        }
    }

    private func latestProgressFile(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              let candidate = files.filter({ $0.pathExtension == "json" }).max(by: {
                  let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  return lhs < rhs
              }) else { return nil }
        return candidate
    }

    private func applyProgress(_ json: [String: Any]) {
        let bytes = (json["bytesVerified"] as? NSNumber)?.doubleValue ?? 0
        let total = (json["totalBytes"] as? NSNumber)?.doubleValue ?? 0
        progressFraction = total > 0 ? min(1, max(0, bytes / total)) : 0
        let resources = (json["resourcesVerified"] as? NSNumber)?.intValue ?? 0
        let totalResources = (json["totalResources"] as? NSNumber)?.intValue ?? 0
        progressText = totalResources > 0 ? "\(resources)/\(totalResources) 项 · \(formatBytes(Int64(bytes))) / \(formatBytes(Int64(total)))" : "已保存 \(formatBytes(Int64(bytes)))"
        if let speed = (json["bytesPerSecond"] as? NSNumber)?.doubleValue, speed > 0 {
            speedText = "\(formatBytes(Int64(speed)))/s"
        } else {
            speedText = "速度计算中"
        }
        if let eta = (json["etaSeconds"] as? NSNumber)?.doubleValue, eta.isFinite {
            etaText = "约剩 \(formatDuration(eta))"
        } else {
            etaText = "剩余时间计算中"
        }
        currentResource = (json["currentResource"] as? String) ?? ""
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }

    nonisolated private static func executeScript(_ name: String, arguments: [String]) throws -> ScriptResult {
        let script = try scriptURL(name)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? "脚本输出无法按 UTF-8 读取。"
        return ScriptResult(success: process.terminationStatus == 0, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func scriptURL(_ name: String) throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("scripts", isDirectory: true).appendingPathComponent(name),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled
        }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.isReadableFile(atPath: local.path) else {
            throw NSError(domain: "PhotoBridgeMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到随 App 打包的 \(name)"])
        }
        return local
    }
}

extension Color {
    static let macBridgeBlue = Color(red: 0.16, green: 0.52, blue: 0.96)
    static let macBridgeSky = Color(red: 0.90, green: 0.95, blue: 1.0)
    static let macBridgeInk = Color(red: 0.08, green: 0.13, blue: 0.22)
    static let macBridgeMuted = Color(red: 0.38, green: 0.47, blue: 0.62)
}

private struct MacBackground: View {
    var body: some View {
        LinearGradient(colors: [.macBridgeSky.opacity(0.74), Color(nsColor: .windowBackgroundColor), .white.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}

private struct MacCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 7)
    }
}

private struct MacIconCircle: View {
    let systemImage: String
    let tint: Color
    var body: some View {
        Image(systemName: systemImage).font(.system(size: 23, weight: .semibold)).foregroundStyle(tint)
            .frame(width: 54, height: 54).background(tint.opacity(0.12), in: Circle())
    }
}

private struct MacStatusPill: View {
    let connected: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(connected ? .green : .gray.opacity(0.6)).frame(width: 9, height: 9)
            Text(connected ? "已连接 · USB" : "等待连接").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.65), in: Capsule())
    }
}

@main
struct PhotoBridgeMacApp: App {
    @StateObject private var transfer = MacTransferModel()
    @State private var section = "home"
    var body: some Scene {
        WindowGroup("PhotoBridge") {
            NavigationSplitView {
                List(selection: $section) {
                    Section {
                        Label("照片传输", systemImage: "photo.on.rectangle.angled").tag("home")
                        Label("iPhone → Mac", systemImage: "arrow.down.to.line.compact").tag("export")
                        Label("Mac → iPhone", systemImage: "arrow.up.to.line.compact").tag("import")
                    }
                    Section("最近保存") {
                        if transfer.recentBackups.isEmpty { Text("还没有保存记录").foregroundStyle(.secondary) }
                        else { ForEach(transfer.recentBackups, id: \.self) { path in Text(URL(fileURLWithPath: path).lastPathComponent).tag(path) } }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("PhotoBridge")
                .frame(minWidth: 210)
            } detail: {
                ZStack {
                    MacBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("照片传输").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.macBridgeInk)
                                    Text("在 iPhone 和 Mac 之间保留原相册顺序").font(.title3).foregroundStyle(.secondary)
                                }
                                Spacer()
                                MacStatusPill(connected: transfer.usbState == "已连接")
                            }

                            MacCard {
                                HStack(spacing: 16) {
                                    MacIconCircle(systemImage: "iphone.gen3", tint: .macBridgeBlue)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(transfer.usbState == "已连接" ? "已连接到 iPhone" : "连接 iPhone 后开始") .font(.title3.weight(.semibold))
                                        Text(transfer.usbState == "已连接" ? "USB 有线连接" : "解锁 iPhone 并点“信任此电脑”") .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("检查连接") { transfer.discover() }.buttonStyle(.bordered).controlSize(.large)
                                }
                            }

                            HStack(alignment: .top, spacing: 16) {
                                MacActionCard(title: "开始导出", subtitle: "将 iPhone 相册保存到 Mac", icon: "arrow.down.to.line.compact", tint: .macBridgeBlue) {
                                    transfer.refreshSessions()
                                } secondary: {
                                    if transfer.sessions.isEmpty { Text("先在 iPhone 选择相册并开始准备").font(.caption).foregroundStyle(.secondary) }
                                    else {
                                        Picker("手机保存", selection: $transfer.selectedSession) { ForEach(transfer.sessions, id: \.self) { value in Text(String(value.prefix(8))).tag(value) } }
                                        Button("选择文件夹并保存") { transfer.downloadSelected() }.buttonStyle(.borderedProminent).tint(.macBridgeBlue)
                                    }
                                }
                                MacActionCard(title: "导入到 iPhone", subtitle: "从 Mac 选择照片文件夹", icon: "arrow.up.to.line.compact", tint: .macBridgeBlue) {
                                    transfer.uploadBackup()
                                } secondary: {
                                    Text("按原相册顺序发送，回到 iPhone 完成恢复").font(.caption).foregroundStyle(.secondary)
                                }
                            }

                            if transfer.busy {
                                MacCard {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack { Text(transfer.progressText).font(.callout.monospacedDigit()); Spacer(); Text(transfer.speedText).font(.caption).foregroundStyle(.secondary) }
                                        ProgressView(value: transfer.progressFraction).tint(.macBridgeBlue)
                                        HStack { Text(transfer.etaText).font(.caption).foregroundStyle(.secondary); Spacer(); Button("暂停并保留进度") { transfer.requestCancel() }.buttonStyle(.bordered) }
                                    }
                                }
                            }

                            Text(transfer.userMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("原照片不会删除、覆盖或改变。").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(30).frame(maxWidth: 980, alignment: .leading)
                    }
                }
                .onAppear { transfer.discover(); transfer.refreshSessions() }
            }
            .frame(minWidth: 940, minHeight: 640)
        }
    }
}

private struct MacActionCard<Secondary: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void
    let secondary: Secondary
    init(title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void, @ViewBuilder secondary: () -> Secondary) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.tint = tint; self.action = action; self.secondary = secondary()
    }
    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 14) {
                MacIconCircle(systemImage: icon, tint: tint)
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                Button("开始") { action() }.buttonStyle(.borderedProminent).tint(tint).controlSize(.large)
                secondary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}
