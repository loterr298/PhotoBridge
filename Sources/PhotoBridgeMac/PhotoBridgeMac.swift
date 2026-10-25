import AppKit
import Foundation
import ImageCaptureCore
import SwiftUI
import QuickLookThumbnailing

struct BackupAssetPreview: Identifiable {
    let id: Int
    let ordinal: Int
    let primaryFilename: String
    let mediaURL: URL
}

struct RemoteAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
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
    @Published var albums: [RemoteAlbum] = []
    @Published var selectedAlbumID = ""
    @Published var remoteStageText = ""
    @Published var loadingAlbums = false
    @Published var progressIndeterminate = true
    @Published var savedFolder: URL?
    @Published var allowCloudDownload = false
    @Published var showAlbum = false
    @Published var savedAlbumName = "已保存的相册"
    private var pendingExportTask: Task<Void, Never>?
    private var activeExportRequestID: String?

    private let bundleIdentifier = "com.photobridge.OrderProbe"
    private var progressTask: Task<Void, Never>?
    private var controlFile: URL?

    init() {
        recentBackups = UserDefaults.standard.stringArray(forKey: "PhotoBridge.recentBackups") ?? []
        if let path = recentBackups.first, FileManager.default.fileExists(atPath: path) { savedFolder = URL(fileURLWithPath: path) }
    }

    func discover() {
        runScript("usb_probe.py", arguments: ["discover", "--bundle", bundleIdentifier]) { [weak self] result in
            self?.usbState = result.success ? "已连接" : "未连接"
            self?.userMessage = result.success ? "iPhone 已连接，可以开始保存。" : "还没有连接 iPhone，请检查数据线和信任设置。"
            self?.output = result.text
            if result.success { self?.refreshAlbums() }
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

    /// Ask the open iPhone app for its real Photos album list. The Mac owns
    /// the selection; the phone only returns public PhotoKit data.
    func refreshAlbums() {
        guard !busy && !loadingAlbums else { return }
        guard usbState == "已连接" else {
            userMessage = "请先连接并信任 iPhone。"
            return
        }
        let id = UUID().uuidString
        loadingAlbums = true
        userMessage = "正在读取 iPhone 相册…"
        let payload: [String: Any] = ["id": id, "kind": "listAlbums"]
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingAlbums = false }
            do {
                try await self.sendControl(payload, requestID: id)
                let response = try await self.waitForControlResponse(id: id)
                guard let values = response["albums"] as? [[String: Any]] else {
                    throw NSError(domain: "PhotoBridgeMac", code: 12, userInfo: [NSLocalizedDescriptionKey: "iPhone 没有返回相册列表"])
                }
                let loaded = values.compactMap { value -> RemoteAlbum? in
                    guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
                    return RemoteAlbum(id: id, name: name, count: (value["count"] as? NSNumber)?.intValue ?? 0)
                }
                await MainActor.run {
                    self.albums = loaded
                    if !loaded.contains(where: { $0.id == self.selectedAlbumID }) { self.selectedAlbumID = loaded.first?.id ?? "" }
                    self.userMessage = loaded.isEmpty ? "没有可用相册，请在 iPhone 允许访问照片。" : "已加载 \(loaded.count) 个相册"
                }
            } catch {
                await MainActor.run { self.userMessage = "读取相册失败：\(error.localizedDescription)" }
            }
        }
    }

    /// The Mac initiates Photos reading and receives each published asset as
    /// soon as it is ready, without waiting for the whole phone album to stage.
    func startMacExport(previous: URL? = nil, resumeSession: String? = nil, existingRequestID: String? = nil) {
        guard !busy && !loadingAlbums else { return }
        guard let album = albums.first(where: { $0.id == selectedAlbumID }) else { userMessage = "请先选择一个相册。"; return }
        guard let parent = previous?.deletingLastPathComponent() ?? chooseDirectory(title: "选择照片保存位置") else { return }
        let requestID = existingRequestID ?? UUID().uuidString
        let folderID = existingRequestID == nil ? requestID : UUID().uuidString
        let safeName = album.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let folder = parent.appendingPathComponent("\(String(safeName.prefix(80)))-\(folderID.prefix(8))", isDirectory: true)
        rememberBackup(folder)
        savedFolder = folder
        busy = true; progressIndeterminate = true; progressFraction = 0
        progressIndeterminate = true
        progressText = "正在连接 iPhone…"; speedText = ""; etaText = ""; currentResource = ""
        userMessage = "保存位置：\(folder.path)"
        activeExportRequestID = requestID
        let allowNetwork = allowCloudDownload
        pendingExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if existingRequestID == nil {
                    var command: [String: Any] = ["id": requestID, "kind": "startExport", "albumIdentifier": album.id, "allowNetwork": allowNetwork]
                    if let resumeSession { command["resumeSession"] = resumeSession }
                    try await sendControl(command, requestID: requestID)
                    _ = try await waitForControlResponse(id: requestID)
                }
                try Task.checkCancellation()
                busy = false
                var arguments = ["live", "--request-id", requestID, "--album-id", album.id,
                                 "--local", folder.path, "--bundle", bundleIdentifier, "--flat"]
                if let previous { arguments += ["--previous", previous.path] }
                runScript("album_export.py", arguments: arguments,
                          progressFile: folder.appendingPathComponent(".photobridge-transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
                    guard let self else { return }
                    self.output = result.text
                    self.activeExportRequestID = nil; self.pendingExportTask = nil
                    self.userMessage = result.success ? "全部照片已保存到：\(folder.path)" : "导出没有完成。保存位置：\(folder.path)"
                    if !result.success {
                        self.stopPhoneExport(requestID)
                        if let data = result.text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let error = json["error"] as? String { self.userMessage += "\n原因：\(error)" }
                    }
                    if result.success { self.loadPreview(from: folder) }
                }
            } catch {
                busy = false; activeExportRequestID = nil; pendingExportTask = nil
                stopPhoneExport(requestID)
                userMessage = error is CancellationError ? "已暂停，原照片不受影响。" : "导出没有完成：\(error.localizedDescription)"
            }
        }
    }

    func continueMacExport() {
        guard !busy && !loadingAlbums else { return }
        guard let previous = chooseDirectory(title: "选择未完成的导出文件夹"),
              let data = try? Data(contentsOf: metadataFile(in: previous, name: "transfer-progress.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albumID = json["albumIdentifier"] as? String,
              let remote = json["remote"] as? String, remote.hasPrefix("Exports/"),
              let session = remote.split(separator: "/").last.map(String.init), UUID(uuidString: session) != nil,
              albums.contains(where: { $0.id == albumID }) else {
            userMessage = "这份导出无法继续，请先读取 iPhone 相册，再选择包含保存记录的未完成文件夹。"
            return
        }
        selectedAlbumID = albumID
        busy = true; progressIndeterminate = true; progressText = "正在检查上次保存…"
        pendingExportTask = Task {
            do {
                let result = try await executeScriptAsync("mac_control.py", arguments: ["resume-plan", "--bundle", bundleIdentifier,
                    "--payload-file", metadataFile(in: previous, name: "transfer-progress.json").path])
                try Task.checkCancellation()
                guard result.success, let data = result.text.data(using: .utf8),
                      let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "PhotoBridgeMac", code: 16, userInfo: [NSLocalizedDescriptionKey: result.text])
                }
                busy = false; pendingExportTask = nil
                // A completed phone export is reused; never ask Photos to restart it.
                startMacExport(previous: previous, resumeSession: plan["resumeSession"] as? String,
                               existingRequestID: plan["existingRequestID"] as? String)
            } catch {
                busy = false; pendingExportTask = nil
                userMessage = "暂时无法继续：\(error.localizedDescription)"
            }
        }
    }

    private func stopPhoneExport(_ target: String) {
        Task {
            let id = UUID().uuidString
            try? await sendControl(["id": id, "kind": "stopExport", "targetRequestID": target], requestID: id)
        }
    }

    func openSavedFolder() {
        if let folder = savedFolder { NSWorkspace.shared.open(folder) }
    }

    private func sendControl(_ payload: [String: Any], requestID: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoBridge-request-\(requestID).json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await executeScriptAsync("mac_control.py", arguments: ["send", "--bundle", bundleIdentifier, "--request-id", requestID, "--payload-file", file.path])
        guard result.success else { throw NSError(domain: "PhotoBridgeMac", code: 13, userInfo: [NSLocalizedDescriptionKey: result.text]) }
    }

    private func waitForControlResponse(id: String) async throws -> [String: Any] {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let result = try await executeScriptAsync("mac_control.py", arguments: ["read", "--bundle", bundleIdentifier, "--path", "Control/Responses/\(id).json"])
            if result.success, let data = result.text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (json["status"] as? String) == "FAILED" { throw NSError(domain: "PhotoBridgeMac", code: 14, userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "iPhone 操作失败"]) }
                return json
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "PhotoBridgeMac", code: 15, userInfo: [NSLocalizedDescriptionKey: "iPhone 没有回应，请保持 PhotoBridge 打开并解锁手机"])
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
        runScript("upload_resume.py", arguments: ["--local", directory.path], progressDirectory: uploadJournalDirectory(in: directory), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "发送没有完成，请重新连接 iPhone 后重试。"
        }
    }

    func resumeUpload() {
        guard let directory = chooseDirectory(title: "选择上次未完成的照片") else { return }
        let journalDirectory = uploadJournalDirectory(in: directory)
        guard let journals = try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: [.contentModificationDateKey]),
              let journal = journals.filter({ $0.pathExtension == "json" && (journalDirectory != directory || $0.lastPathComponent.hasPrefix(".photobridge-upload-")) }).max(by: {
                  let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  return lhs < rhs
              }) else {
            output = "找不到可以继续的备份，请先选择一份已保存的照片。"
            userMessage = output
            return
        }
        guard let journalData = try? Data(contentsOf: journal),
              let state = try? JSONSerialization.jsonObject(with: journalData) as? [String: Any], state["owner"] != nil else {
            userMessage = "这份旧版发送记录不能继续，请重新选择文件夹发送。已收到的文件会保留。"
            return
        }
        userMessage = "正在继续发送照片到 iPhone…"
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--resume-journal", journal.path], progressDirectory: journalDirectory, controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "继续发送没有完成，请重试。"
        }
    }

    func requestCancel() {
        pendingExportTask?.cancel()
        if let request = activeExportRequestID { stopPhoneExport(request) }
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

    private func metadataFile(in folder: URL, name: String) -> URL {
        let flat = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path)
        return folder.appendingPathComponent(flat ? ".photobridge-" + name : name)
    }

    private func uploadJournalDirectory(in folder: URL) -> URL {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path)
            ? folder : folder.appendingPathComponent("restore-uploads", isDirectory: true)
    }

    func viewSavedAlbum() {
        guard let folder = savedFolder ?? chooseDirectory(title: "选择已保存的相册") else { return }
        savedFolder = folder; loadPreview(from: folder); showAlbum = true
    }

    func chooseSavedAlbum() {
        guard let folder = chooseDirectory(title: "选择已保存的相册文件夹") else { return }
        rememberBackup(folder); savedFolder = folder; loadPreview(from: folder); showAlbum = true
    }

    private func loadPreview(from folder: URL) {
        savedFolder = folder
        let sourceURL = metadataFile(in: folder, name: "source-order.json")
        if let data = try? Data(contentsOf: sourceURL), let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            savedAlbumName = source["albumName"] as? String ?? "已保存的相册"
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path) {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)) ?? []
            backupPreview = files.filter { url in
                let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return info?.isRegularFile == true && info?.isSymbolicLink != true && Int(url.lastPathComponent.split(separator: "_", maxSplits: 1).first ?? "") != nil
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }.enumerated().map { index, url in
                BackupAssetPreview(id: index, ordinal: Int(url.lastPathComponent.split(separator: "_", maxSplits: 1)[0]) ?? index + 1,
                    primaryFilename: url.lastPathComponent, mediaURL: url)
            }
            return
        }
        let assets: [[String: Any]]
        if let data = try? Data(contentsOf: metadataFile(in: folder, name: "album-order.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let complete = object["assets"] as? [[String: Any]] { assets = complete }
        else {
            let records = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("asset-records"), includingPropertiesForKeys: nil)) ?? []
            assets = records.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
                guard let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }
        backupPreview = assets.enumerated().compactMap { index, asset in
            let resources = asset["resources"] as? [[String: Any]] ?? []
            let preferred = (asset["mediaType"] as? Int) == 2 ? [6,2] : [5,1,4]
            let resource = preferred.lazy.compactMap { type in resources.first { ($0["resourceType"] as? Int) == type } }.first ?? resources.first
            guard let relative = resource?["storedRelativePath"] as? String else { return nil }
            let file = folder.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard file.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
            return BackupAssetPreview(id: index, ordinal: (asset["ordinal"] as? NSNumber)?.intValue ?? index + 1,
                primaryFilename: resource?["originalFilename"] as? String ?? "照片", mediaURL: file)
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
        progressIndeterminate = true
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
            if let progressFile, let data = try? Data(contentsOf: progressFile),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { applyProgress(json) }
            progressTask?.cancel()
            if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
            self.controlFile = nil
            busy = false
            completion(result)
        }
    }

    private func executeScriptAsync(_ name: String, arguments: [String]) async throws -> ScriptResult {
        try await Task.detached(priority: .utility) {
            try Self.executeScript(name, arguments: arguments)
        }.value
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
              let candidate = files.filter({ $0.pathExtension == "json" && (!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".photobridge-layout.json").path) || $0.lastPathComponent.hasPrefix(".photobridge-upload-")) }).max(by: {
                  let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  return lhs < rhs
              }) else { return nil }
        return candidate
    }

    private func applyProgress(_ json: [String: Any]) {
        if let assets = (json["assetsVerified"] as? NSNumber)?.intValue {
            let total = (json["totalAssets"] as? NSNumber)?.intValue ?? 0
            let state = json["status"] as? String ?? ""
            progressIndeterminate = total == 0 || state == "FINALIZING"
            progressFraction = total > 0 ? min(state == "COMMITTED" ? 1 : 0.99, Double(assets) / Double(total)) : 0
            if total == 0 {
                let scanned = (json["scannedAssets"] as? NSNumber)?.intValue ?? 0
                let scanTotal = (json["scanTotalAssets"] as? NSNumber)?.intValue ?? 0
                progressText = scanTotal > 0 ? "正在读取相册：\(scanned.formatted()) / \(scanTotal.formatted()) 张" : "正在读取相册…"
                progressIndeterminate = scanTotal == 0
                progressFraction = scanTotal > 0 ? Double(scanned) / Double(scanTotal) : 0
            } else {
                progressText = state == "FINALIZING" ? "全部照片已接收，正在核对保存记录…" : "已保存 \(assets.formatted()) / \(total.formatted()) 张"
            }
            if json["phoneInForeground"] as? Bool == false {
                progressText = "请回到 iPhone 的 PhotoBridge，继续准备照片"
            }
            let bytes = (json["bytesVerified"] as? NSNumber)?.int64Value ?? 0
            if let speed = (json["bytesPerSecond"] as? NSNumber)?.doubleValue, speed > 0 {
                speedText = "\(formatBytes(Int64(speed)))/s · 已保存 \(formatBytes(bytes))"
            } else { speedText = "" }
            etaText = "" // Total original byte count is unknown until PhotoKit reads it.
            currentResource = json["currentResource"] as? String ?? ""
            return
        }
        progressIndeterminate = false
        let bytes = (json["bytesVerified"] as? NSNumber)?.doubleValue ?? 0
        let total = (json["totalBytes"] as? NSNumber)?.doubleValue ?? 0
        progressFraction = total > 0 ? min((json["state"] as? String) == "UPLOADING" ? 0.99 : 1, max(0, bytes / total)) : 0
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
        LinearGradient(colors: [.macBridgeSky.opacity(0.66), Color.white.opacity(0.84), .white], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
}

private struct MacCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(20)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.92), lineWidth: 1))
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
            Text(connected ? "已连接 · 数据线" : "等待连接").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92), in: Capsule())
    }
}

@main
struct PhotoBridgeMacApp: App {
    @StateObject private var transfer = MacTransferModel()
    var body: some Scene {
        WindowGroup("PhotoBridge") {
            ZStack {
                MacBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("照片传输").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.macBridgeInk)
                                Text("两步完成照片备份和导入").font(.title3).foregroundStyle(.secondary)
                            }
                            Spacer()
                            MacStatusPill(connected: transfer.usbState == "已连接")
                        }

                        MacCard {
                            HStack(spacing: 16) {
                                MacIconCircle(systemImage: "iphone.gen3", tint: .macBridgeBlue)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(transfer.usbState == "已连接" ? "iPhone 已连接" : "请连接 iPhone") .font(.title3.weight(.semibold))
                                    Text(transfer.usbState == "已连接" ? "数据线连接已就绪" : "解锁 iPhone 并点“信任此电脑”") .font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("检查连接") { transfer.discover() }.disabled(transfer.busy || transfer.loadingAlbums).buttonStyle(.bordered).controlSize(.large)
                            }
                        }

                        MacCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    Text("1").font(.headline).foregroundStyle(.white).frame(width: 30, height: 30).background(Color.macBridgeBlue, in: Circle())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("导出到 Mac").font(.title3.weight(.semibold))
                                        Text("在这里选择相册和保存位置，照片会按原顺序逐张写入 Mac").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 10) {
                                    Button(transfer.loadingAlbums ? "正在读取相册…" : "刷新相册") { transfer.refreshAlbums() }.disabled(transfer.busy || transfer.loadingAlbums).buttonStyle(.bordered).controlSize(.large)
                                    if transfer.albums.isEmpty { Text("连接后读取相册").font(.subheadline).foregroundStyle(.secondary) }
                                }
                                if !transfer.albums.isEmpty {
                                    Picker("相册", selection: $transfer.selectedAlbumID) {
                                        ForEach(transfer.albums) { album in
                                            Text("\(album.name) · \(album.count.formatted()) 张").tag(album.id)
                                        }
                                    }
                                }
                                Toggle("需要时从 iCloud 获取原图", isOn: $transfer.allowCloudDownload).disabled(transfer.busy)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button {
                                    transfer.startMacExport()
                                } label: {
                                    Label("选择文件夹并开始导出", systemImage: "arrow.down.to.line.compact")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.macBridgeBlue).controlSize(.large)
                                .disabled(transfer.busy || transfer.loadingAlbums || transfer.selectedAlbumID.isEmpty)
                                Button("继续未完成的导出") { transfer.continueMacExport() }
                                    .disabled(transfer.busy || transfer.loadingAlbums || transfer.albums.isEmpty)
                                    .buttonStyle(.bordered)
                                if !transfer.remoteStageText.isEmpty {
                                    Text(transfer.remoteStageText).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }

                        MacCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    Text("2").font(.headline).foregroundStyle(.white).frame(width: 30, height: 30).background(Color.macBridgeBlue, in: Circle())
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("从 Mac 导出到 iPhone").font(.title3.weight(.semibold))
                                        Text("选择 Mac 上的照片文件夹，按原顺序发送到 iPhone").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 10) {
                                    Button("选择文件夹并发送") { transfer.uploadBackup() }.buttonStyle(.borderedProminent).tint(.macBridgeBlue).controlSize(.large)
                                    Button("继续上次发送") { transfer.resumeUpload() }.buttonStyle(.bordered).controlSize(.large)
                                }
                            }
                        }

                        if transfer.busy {
                            MacCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Text("当前进度").font(.headline); Spacer(); Text(transfer.speedText).font(.caption).foregroundStyle(.secondary) }
                                    if transfer.progressIndeterminate { ProgressView().controlSize(.small) }
                                    else { ProgressView(value: transfer.progressFraction).tint(.macBridgeBlue) }
                                    if !transfer.currentResource.isEmpty { Text(transfer.currentResource).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    HStack { Text(transfer.progressText).font(.callout.monospacedDigit()); Spacer(); Text(transfer.etaText).font(.caption).foregroundStyle(.secondary) }
                                    Button("暂停并保留进度") { transfer.requestCancel() }.buttonStyle(.bordered)
                                }
                            }
                        }

                        Button("打开已保存的相册…") { transfer.chooseSavedAlbum() }.buttonStyle(.bordered)
                        if transfer.savedFolder != nil {
                            HStack {
                                Button("查看已保存照片") { transfer.viewSavedAlbum() }.buttonStyle(.borderedProminent).tint(.macBridgeBlue)
                                Button("在 Finder 中打开文件夹") { transfer.openSavedFolder() }.buttonStyle(.bordered)
                            }
                            Text("所有照片保存在同一文件夹；按名称升序查看，就是相册顺序。").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(transfer.userMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("原照片不会删除、覆盖或改变。").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(30).frame(maxWidth: 900, alignment: .leading)
                }
            }
            .frame(minWidth: 760, minHeight: 650)
            .sheet(isPresented: $transfer.showAlbum) { SavedAlbumView(model: transfer) }
            .onAppear { transfer.discover() }
        }
    }
}
