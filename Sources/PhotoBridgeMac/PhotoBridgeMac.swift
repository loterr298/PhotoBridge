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
                return
            }
            self?.sessions = values
            self?.selectedSession = values.first ?? ""
        }
    }

    func downloadSelected() {
        guard !selectedSession.isEmpty else { output = "请先查找并选择一份手机备份。"; return }
        guard let parent = chooseDirectory(title: "选择照片保存位置") else { return }
        let folder = parent.appendingPathComponent("PhotoBridge-\(String(selectedSession.prefix(8)))", isDirectory: true)
        rememberBackup(folder)
        runScript("album_export.py", arguments: ["download", "--remote", "Exports/\(selectedSession)", "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            if result.success { self?.loadPreview(from: folder) }
        }
    }

    func resumeSelected() {
        guard !selectedSession.isEmpty else { output = "请先查找并选择一份手机备份。"; return }
        guard let previous = chooseDirectory(title: "选择上次未完成的备份") else { return }
        guard let parent = chooseDirectory(title: "选择继续保存的位置") else { return }
        let folder = parent.appendingPathComponent("PhotoBridge-resume-\(String(selectedSession.prefix(8)))", isDirectory: true)
        rememberBackup(folder)
        runScript("album_resume.py", arguments: ["--remote", "Exports/\(selectedSession)", "--from-directory", previous.path, "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            if result.success { self?.loadPreview(from: folder) }
        }
    }

    func uploadBackup() {
        guard let directory = chooseDirectory(title: "选择要发送到 iPhone 的照片") else { return }
        runScript("album_restore.py", arguments: ["--local", directory.path, "--bundle", bundleIdentifier], progressDirectory: directory.appendingPathComponent("restore-uploads", isDirectory: true), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
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
            return
        }
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--resume-journal", journal.path], progressDirectory: journalDirectory, controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
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

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.1), in: Capsule())
    }
}

@main
struct PhotoBridgeMacApp: App {
    @StateObject private var discovery = CameraDiscovery()
    @StateObject private var transfer = MacTransferModel()

    var body: some Scene {
        WindowGroup("PhotoBridge · 照片") {
            NavigationSplitView {
                List {
                    Section("设备") {
                        Label("iPhone", systemImage: "iphone")
                        StatusPill(text: transfer.usbState, systemImage: "cable.connector", tint: transfer.usbState == "已连接" ? .green : .secondary)
                    }
                    Section("功能") {
                        Label("保存照片", systemImage: "arrow.down.circle")
                        Label("恢复到 iPhone", systemImage: "arrow.up.circle")
                        Label("查看相机照片", systemImage: "camera")
                    }
                    Section("最近备份") {
                        if transfer.recentBackups.isEmpty {
                            Text("完成一次下载后会显示在这里")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(transfer.recentBackups, id: \.self) { path in
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.caption)
                                    .help(path)
                            }
                        }
                    }
                    Section("相机照片（辅助）") {
                        ForEach(discovery.devices.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(discovery.devices[index].name ?? "未命名设备")
                                Text(discovery.devices[index].transportType ?? "未知链路")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if discovery.devices.isEmpty {
                            Text("没有找到相机")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationTitle("PhotoBridge")
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("照片传输").font(.largeTitle.bold())
                                Text("保留原图 · 安全检查")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: transfer.usbState, systemImage: "cable.connector", tint: transfer.usbState == "已连接" ? .green : .secondary)
                        }

                        GroupBox("连接 iPhone") {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("开始前先连接", systemImage: "cable.connector.horizontal")
                                    .font(.headline)
                                Text("用数据线连接 iPhone，解锁并点“信任”。照片顺序来自 iPhone 相册，相机照片只作为辅助查看。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("检查连接") { transfer.discover() }
                                        .buttonStyle(.borderedProminent)
                                    Button("查找手机备份") { transfer.refreshSessions() }
                                        .buttonStyle(.bordered)
                                    Button("查看相机") { discovery.start() }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }

                        GroupBox("手机备份") {
                            VStack(alignment: .leading, spacing: 12) {
                                if transfer.sessions.isEmpty {
                                    Text("还没有找到备份。请先在 iPhone 选择一个相册并开始保存。")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("备份", selection: $transfer.selectedSession) {
                                        ForEach(transfer.sessions, id: \.self) { session in
                                            Text(String(session.prefix(8))).tag(session)
                                        }
                                    }
                                    HStack {
                                        Button("保存到 Mac") { transfer.downloadSelected() }
                                            .buttonStyle(.borderedProminent)
                                        Button("继续上次保存") { transfer.resumeSelected() }
                                            .buttonStyle(.bordered)
                                        Text("每张照片都会检查完整，并按原相册顺序整理")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if transfer.busy {
                                    ProgressView(value: transfer.progressFraction)
                                    HStack(spacing: 14) {
                                        Text(transfer.progressText)
                                        Text(transfer.speedText)
                                        Text(transfer.etaText)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    Button("暂停并保留进度") { transfer.requestCancel() }
                                        .buttonStyle(.bordered)
                                    if !transfer.currentResource.isEmpty {
                                        Text(transfer.currentResource)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        if !transfer.backupPreview.isEmpty {
                            GroupBox("备份内容") {
                                VStack(spacing: 0) {
                                    HStack {
                                        Text("位置").frame(width: 54, alignment: .leading)
                                        Text("照片").frame(maxWidth: .infinity, alignment: .leading)
                                        Text("文件").frame(width: 50, alignment: .trailing)
                                        Text("大小").frame(width: 88, alignment: .trailing)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 8)
                                    ForEach(transfer.backupPreview.prefix(12)) { asset in
                                        HStack {
                                            Text(String(format: "%04d", asset.ordinal)).frame(width: 54, alignment: .leading)
                                            Text(asset.primaryFilename).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                            Text("\(asset.resourceCount)").frame(width: 50, alignment: .trailing)
                                            Text(ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))
                                                .frame(width: 88, alignment: .trailing)
                                        }
                                        .font(.caption.monospacedDigit())
                                        .padding(.vertical, 5)
                                        Divider()
                                    }
                                    if transfer.backupPreview.count > 12 {
                                        Text("这里只显示前 12 张，完整照片已保存在你选择的文件夹")
                                            .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                                    }
                                }
                            }
                        }

                        GroupBox("恢复到 iPhone") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("选择一份已保存的照片，发送到 iPhone 后，在 iPhone 上确认恢复。")
                                    .foregroundStyle(.secondary)
                                Button("选择照片并发送") { transfer.uploadBackup() }
                                    .buttonStyle(.bordered)
                                Button("继续上次发送") { transfer.resumeUpload() }
                                    .buttonStyle(.bordered)
                                if transfer.busy {
                                    ProgressView(value: transfer.progressFraction)
                                    HStack(spacing: 14) {
                                        Text(transfer.progressText)
                                        Text(transfer.speedText)
                                        Text(transfer.etaText)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    Button("暂停并保留进度") { transfer.requestCancel() }
                                        .buttonStyle(.bordered)
                                    if !transfer.currentResource.isEmpty {
                                        Text(transfer.currentResource)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }

                        DisclosureGroup("查看详细信息") {
                            Text(transfer.output.isEmpty ? "暂无输出" : transfer.output)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("原照片不会删除、覆盖或改变。遇到问题时，已完成的照片和进度都会保留。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .frame(maxWidth: 960, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .frame(minWidth: 900, minHeight: 640)
            .onAppear { discovery.start() }
        }
    }
}
