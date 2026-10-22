import AppKit
import Foundation
import ImageCaptureCore
import SwiftUI

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
    @Published var usbState = "尚未检测"
    @Published var output = "连接 iPhone、解锁并信任此 Mac，然后点“检测 USB”。"
    @Published var sessions: [String] = []
    @Published var selectedSession = ""
    @Published var busy = false

    private let bundleIdentifier = "com.photobridge.OrderProbe"

    func discover() {
        runScript("usb_probe.py", arguments: ["discover", "--bundle", bundleIdentifier]) { [weak self] result in
            self?.usbState = result.success ? "USB 已发现" : "USB 未连接"
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
        guard !selectedSession.isEmpty else { output = "请先读取并选择一个手机暂存会话。"; return }
        guard let parent = chooseDirectory(title: "选择 Mac 备份位置") else { return }
        let folder = parent.appendingPathComponent("PhotoBridge-\(String(selectedSession.prefix(8)))", isDirectory: true)
        runScript("album_export.py", arguments: ["download", "--remote", "Exports/\(selectedSession)", "--local", folder.path, "--bundle", bundleIdentifier]) { [weak self] result in
            self?.output = result.text
        }
    }

    func uploadBackup() {
        guard let directory = chooseDirectory(title: "选择已校验的 PhotoBridge 备份目录") else { return }
        runScript("album_restore.py", arguments: ["--local", directory.path, "--bundle", bundleIdentifier]) { [weak self] result in
            self?.output = result.text
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

    private func runScript(_ name: String, arguments: [String], completion: @escaping (ScriptResult) -> Void) {
        guard !busy else { return }
        busy = true
        output = "正在执行 \(name)…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> ScriptResult in
                do {
                    return try Self.executeScript(name, arguments: arguments)
                } catch {
                    return ScriptResult(success: false, text: "未完成：\(error.localizedDescription)")
                }
            }.value
            busy = false
            completion(result)
        }
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
        WindowGroup("PhotoBridge · USB 传输") {
            NavigationSplitView {
                List {
                    Section("设备") {
                        Label("iPhone · USB", systemImage: "iphone")
                        StatusPill(text: transfer.usbState, systemImage: "cable.connector", tint: transfer.usbState == "USB 已发现" ? .green : .secondary)
                    }
                    Section("工具") {
                        Label("原始资源备份", systemImage: "arrow.down.circle")
                        Label("恢复到 iPhone", systemImage: "arrow.up.circle")
                        Label("相机目录诊断", systemImage: "camera")
                    }
                    Section("ImageCaptureCore / PTP") {
                        ForEach(discovery.devices.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(discovery.devices[index].name ?? "未命名设备")
                                Text(discovery.devices[index].transportType ?? "未知链路")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if discovery.devices.isEmpty {
                            Text("未发现相机目录")
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
                                Text("原图保持 · USB-only · 可校验")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusPill(text: transfer.usbState, systemImage: "cable.connector", tint: transfer.usbState == "USB 已发现" ? .green : .secondary)
                        }

                        GroupBox {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("真实 USB 通道", systemImage: "cable.connector.horizontal")
                                    .font(.headline)
                                Text("使用 House Arrest/AFC 读取 PhotoBridge Documents。ImageCaptureCore/PTP 只用于相机目录诊断，不能代表相簿手动顺序。")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("检测 USB") { transfer.discover() }
                                        .buttonStyle(.borderedProminent)
                                    Button("读取手机暂存") { transfer.refreshSessions() }
                                        .buttonStyle(.bordered)
                                    Button("刷新相机目录") { discovery.start() }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }

                        GroupBox("手机暂存会话") {
                            VStack(alignment: .leading, spacing: 12) {
                                if transfer.sessions.isEmpty {
                                    Text("尚未读取会话。请先在 iPhone 完成原始资源暂存。")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("会话", selection: $transfer.selectedSession) {
                                        ForEach(transfer.sessions, id: \.self) { session in
                                            Text(String(session.prefix(8))).tag(session)
                                        }
                                    }
                                    HStack {
                                        Button("下载并校验到 Mac") { transfer.downloadSelected() }
                                            .buttonStyle(.borderedProminent)
                                        Text("每项资源独立验证大小、SHA-256 和 5 秒文件时间")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        GroupBox("恢复到 iPhone") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("选择已提交的 PhotoBridge 备份目录后上传到新收件会话；照片库写入仍需在 iPhone 恢复页明确启动。")
                                    .foregroundStyle(.secondary)
                                Button("选择备份并上传") { transfer.uploadBackup() }
                                    .buttonStyle(.bordered)
                            }
                        }

                        GroupBox("真实输出") {
                            Text(transfer.output.isEmpty ? "暂无输出" : transfer.output)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("原始媒体不会删除、覆盖或改写内部 EXIF/GPS/MakerNotes。失败会保留日志和部分文件，不会伪称完成。")
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
