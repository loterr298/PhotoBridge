import AppKit
import PhotoBridgeCore
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
    @Published var connectionMessage = "用数据线连接，解锁并打开手机上的 PhotoBridge。"
    @Published var userMessage = ""
    @Published var output = ""
    @Published var sessions: [String] = []
    @Published var selectedSession = ""
    @Published var busy = false
    @Published var progressFraction = 0.0
    @Published var progressText = ""
    @Published var progressCountText = ""
    @Published var progressPercentText = "—"
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
    @Published var loadingPreview = false
    @Published var previewError = ""
    private var previewTask: Task<(String, [BackupAssetPreview]), Error>?
    private var pendingExportTask: Task<Void, Never>?
    private var pendingUploadTask: Task<Void, Never>?
    private var activeExportRequestID: String?
    private var connectionTask: Task<Void, Never>?
    private var connectionFreshness = ConnectionFreshness()
    private var connectionGeneration = UUID()

    private let bundleIdentifier = "com.photobridge.OrderProbe"
    private var progressTask: Task<Void, Never>?
    private var importProgressTask: Task<Void, Never>?
    private var controlFile: URL?

    init() {
        recentBackups = UserDefaults.standard.stringArray(forKey: "PhotoBridge.recentBackups") ?? []
        if let path = recentBackups.first, FileManager.default.fileExists(atPath: path) { savedFolder = URL(fileURLWithPath: path) }
    }

    func invalidateConnection() {
        connectionGeneration = UUID()
        connectionFreshness.invalidate()
        usbState = "等待连接"
        connectionMessage = "正在自动确认连接…"
    }

    func startConnectionMonitoring() {
        guard connectionTask == nil else { return }
        // Independent checks never reset a transfer or cancel its progress watcher.
        connectionTask = Task { [weak self] in
            var confirmedNonce: String?
            var needsAlbums = false
            while !Task.isCancelled {
                guard let self else { return }
                if !self.connectionFreshness.isConnected(now: ProcessInfo.processInfo.systemUptime) { self.usbState = "等待连接" }
                let nonce = UUID().uuidString
                let generation = self.connectionGeneration
                let started = ProcessInfo.processInfo.systemUptime
                var args = ["heartbeat", "--bundle", self.bundleIdentifier, "--request-id", nonce]
                if let confirmedNonce { args += ["--confirmed-nonce", confirmedNonce] }
                let result = try? await self.executeScriptAsync("mac_control.py", arguments: args)
                guard !Task.isCancelled else { return }
                // A pre-sleep result must not resurrect a connection on wake.
                guard generation == self.connectionGeneration,
                      ProcessInfo.processInfo.systemUptime - started < 5 else {
                    confirmedNonce = nil
                    self.invalidateConnection()
                    continue
                }
                let data = result?.text.data(using: .utf8)
                let value = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let ready = result?.success == true && value?["status"] as? String == "CONNECTED" && value?["nonce"] as? String == nonce
                if ready {
                    if self.usbState != "已连接" { needsAlbums = true }
                    confirmedNonce = nonce
                    self.connectionFreshness.confirm(now: ProcessInfo.processInfo.systemUptime)
                    self.usbState = "已连接"
                    self.connectionMessage = "USB 有线连接 · 请保持手机 App 在前台"
                } else {
                    confirmedNonce = nil
                    self.connectionFreshness.invalidate()
                    self.usbState = "等待连接"
                    self.connectionMessage = value?["status"] as? String == "PHONE_NOT_READY"
                        ? "已找到 iPhone，请解锁并打开最新版 PhotoBridge。"
                        : "用数据线连接，解锁手机并确认“信任此电脑”。"
                }
                if ready && needsAlbums && !self.busy && !self.loadingAlbums {
                    needsAlbums = false
                    self.refreshAlbums()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
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
            if result.terminalFailure { throw NSError(domain: "PhotoBridgeMac", code: 17, userInfo: [NSLocalizedDescriptionKey: result.text]) }
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
        guard !busy && !loadingAlbums else { return }
        guard let directory = chooseDirectory(title: "选择要发送到 iPhone 的照片") else { return }
        userMessage = "正在发送照片到 iPhone…"
        let identity = UUID().uuidString
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--journal-id", identity],
                  progressFile: uploadProgressFile(in: directory, identity: identity), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.observePhoneImport(result)
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "发送没有完成，请重新连接 iPhone 后重试。"
        }
    }

    func resumeUpload() {
        guard !busy && !loadingAlbums else { return }
        guard let directory = chooseDirectory(title: "选择上次未完成的照片") else { return }
        let journalDirectory = uploadJournalDirectory(in: directory)
        busy = true; progressIndeterminate = true; progressText = "正在查找上次发送记录…"
        pendingUploadTask = Task {
        let journal = await Task.detached(priority: .utility) { () -> URL? in
            guard let journals = try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil),
              let journal = journals.filter({ $0.pathExtension == "json" && (journalDirectory != directory || $0.lastPathComponent.hasPrefix(".photobridge-upload-")) }).max(by: {
                  let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                  return lhs < rhs
              }) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: journal.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1024 * 1024,
              let journalData = try? Data(contentsOf: journal),
              let state = try? JSONSerialization.jsonObject(with: journalData) as? [String: Any], state["owner"] != nil else { return nil }
            return journal
        }.value
        guard !Task.isCancelled else {
            busy = false; pendingUploadTask = nil; userMessage = "已暂停，原照片不受影响。"; return
        }
        pendingUploadTask = nil
        busy = false
        guard let journal else {
            userMessage = "找不到可继续的发送记录，请重新选择文件夹发送。已收到的文件会保留。"
            return
        }
        userMessage = "正在继续发送照片到 iPhone…"
        let identity = UUID().uuidString
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--resume-journal", journal.path, "--journal-id", identity],
                  progressFile: uploadProgressFile(in: directory, identity: identity), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.observePhoneImport(result)
            self?.userMessage = result.success ? "照片已发送到 iPhone，请在 iPhone 点“恢复到新相册”。" : "继续发送没有完成，请重试。"
        }
        }
    }

    func requestCancel() {
        pendingExportTask?.cancel()
        pendingUploadTask?.cancel()
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
        Self.metadataURL(in: folder, name: name)
    }
    nonisolated private static func metadataURL(in folder: URL, name: String) -> URL {
        let flat = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path)
        return folder.appendingPathComponent(flat ? ".photobridge-" + name : name)
    }

    private func uploadJournalDirectory(in folder: URL) -> URL {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path)
            ? folder : folder.appendingPathComponent("restore-uploads", isDirectory: true)
    }
    private func uploadProgressFile(in folder: URL, identity: String) -> URL {
        let directory = uploadJournalDirectory(in: folder)
        return directory.appendingPathComponent((directory == folder ? ".photobridge-upload-" : "") + identity + ".json")
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
        previewTask?.cancel()
        savedFolder = folder; loadingPreview = true; previewError = ""; backupPreview = []
        let work = Task.detached(priority: .utility) { try autoreleasepool { try Self.readPreview(from: folder) } }
        previewTask = work
        Task {
            do {
                let (title, photos) = try await work.value
                guard !work.isCancelled, savedFolder == folder else { return }
                savedAlbumName = title; backupPreview = photos; loadingPreview = false; previewTask = nil
            } catch {
                guard !work.isCancelled, savedFolder == folder else { return }
                loadingPreview = false; previewTask = nil; previewError = "暂时无法读取照片，请重新打开文件夹。"
            }
        }
    }
    nonisolated private static func readPreview(from folder: URL) throws -> (String, [BackupAssetPreview]) {
        try Task.checkCancellation()
        var title = "已保存的相册"
        let sourceURL = metadataURL(in: folder, name: "source-order.json")
        if let data = try? Data(contentsOf: sourceURL), let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = source["albumName"] as? String ?? "已保存的相册"
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path) {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            let photos = try files.filter { url in
                try Task.checkCancellation()
                return autoreleasepool {
                    let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    return info?.isRegularFile == true && info?.isSymbolicLink != true && Int(url.lastPathComponent.split(separator: "_", maxSplits: 1).first ?? "") != nil
                }
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }.enumerated().map { index, url in
                BackupAssetPreview(id: index, ordinal: Int(url.lastPathComponent.split(separator: "_", maxSplits: 1)[0]) ?? index + 1,
                    primaryFilename: url.lastPathComponent, mediaURL: url)
            }
            return (title, photos)
        }
        let assets: [[String: Any]]
        if let data = try? Data(contentsOf: metadataURL(in: folder, name: "album-order.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let complete = object["assets"] as? [[String: Any]] { assets = complete }
        else {
            let records = (try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("asset-records"), includingPropertiesForKeys: nil)) ?? []
            assets = try records.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap {
                try Task.checkCancellation()
                guard let data = try? Data(contentsOf: $0) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
        }
        let photos = try assets.enumerated().compactMap { index, asset -> BackupAssetPreview? in
            try Task.checkCancellation()
            let resources = asset["resources"] as? [[String: Any]] ?? []
            let preferred = (asset["mediaType"] as? Int) == 2 ? [6,2] : [5,1,4]
            let resource = preferred.lazy.compactMap { type in resources.first { ($0["resourceType"] as? Int) == type } }.first ?? resources.first
            guard let relative = resource?["storedRelativePath"] as? String else { return nil }
            let file = folder.appendingPathComponent(relative).resolvingSymlinksInPath()
            guard file.path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"), FileManager.default.fileExists(atPath: file.path) else { return nil }
            return BackupAssetPreview(id: index, ordinal: (asset["ordinal"] as? NSNumber)?.intValue ?? index + 1,
                primaryFilename: resource?["originalFilename"] as? String ?? "照片", mediaURL: file)
        }
        return (title, photos)
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
        var terminalFailure = false
    }

    private func runScript(_ name: String, arguments: [String], progressFile: URL? = nil,
                           controlFile: URL? = nil,
                           completion: @escaping (ScriptResult) -> Void) {
        guard !busy else { return }
        busy = true
        importProgressTask?.cancel(); importProgressTask = nil
        progressCountText = ""; progressPercentText = "—"
        self.controlFile = controlFile
        if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
        progressFraction = 0
        progressIndeterminate = true
        progressText = "等待首个进度记录…"
        speedText = ""
        etaText = ""
        currentResource = ""
        startProgressPolling(file: progressFile)
        output = "正在执行 \(name)…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> ScriptResult in
                do {
                    var commandArguments = arguments
                    if let controlFile { commandArguments += ["--cancel-file", controlFile.path] }
                    return try Self.executeScript(name, arguments: commandArguments, cancelFile: controlFile)
                } catch {
                    return ScriptResult(success: false, text: "未完成：\(error.localizedDescription)")
                }
            }.value
            progressTask?.cancel()
            if let progressFile,
               let json = await Task.detached(priority: .utility, operation: { Self.readProgress(progressFile) }).value { applyProgress(json) }
            if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
            self.controlFile = nil
            // Connection/list commands have no transfer progress. Do not leave
            // their initial spinner visible after returning to the idle screen.
            if progressFile == nil { progressText = "" }
            else if !result.success { progressText = "已停止，已保存的进度保留" }
            busy = false
            completion(result)
        }
    }

    private func executeScriptAsync(_ name: String, arguments: [String]) async throws -> ScriptResult {
        try await Task.detached(priority: .utility) {
            try Self.executeScript(name, arguments: arguments)
        }.value
    }

    private func startProgressPolling(file: URL?) {
        progressTask?.cancel()
        guard let file else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self else { return }
                let json = await Task.detached(priority: .utility) { Self.readProgress(file) }.value
                guard !Task.isCancelled else { return }
                if let json { self.applyProgress(json) }
            }
        }
    }

    nonisolated private static func readProgress(_ file: URL) -> [String: Any]? {
        autoreleasepool {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 1024 * 1024,
                  let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func applyProgress(_ json: [String: Any]) {
        func count(_ key: String) -> Int {
            guard let n = json[key] as? NSNumber, let safe = ProgressNumber.nonnegativeInt64(n.doubleValue) else { return 0 }
            return Int(safe)
        }
        let state = json["status"] as? String ?? json["state"] as? String ?? ""
        let uploading = (json["remote"] as? String ?? "").hasPrefix("RestoreInbox/")
        let assets = count("assetsVerified"), total = count("totalAssets")
        let scanning = total == 0
        let done = scanning ? count("scannedAssets") : assets
        let expected = scanning ? count("scanTotalAssets") : total
        let progress = PhotoProgress(completed: done, total: expected,
            finished: ["COMMITTED", "USB_VERIFIED"].contains(state))
        progressIndeterminate = expected == 0
        progressFraction = progress.fraction
        progressCountText = expected > 0 ? progress.countText : "正在读取总张数…"
        progressPercentText = progress.percentText
        if scanning { progressText = "正在读取照片" }
        else if state == "FINALIZING" { progressText = "正在完成最后检查" }
        else if state == "COMMITTED" { progressText = "已保存到 Mac" }
        else if state == "USB_VERIFIED" { progressText = "已发送到 iPhone，等待导入" }
        else if ["STOPPED", "FAILED"].contains(state) { progressText = "尚未完成，进度已保留" }
        else { progressText = uploading ? "正在发送到 iPhone" : "正在保存到 Mac" }
        if json["phoneInForeground"] as? Bool == false { progressText = "请回到 iPhone 的 PhotoBridge，继续准备照片" }
        let bytes = ProgressNumber.nonnegativeInt64((json["bytesVerified"] as? NSNumber)?.doubleValue ?? 0) ?? 0
        if let number = json["bytesPerSecond"] as? NSNumber,
           let speed = ProgressNumber.nonnegativeInt64(number.doubleValue), speed > 0 {
            speedText = "\(formatBytes(speed))/s · \(formatBytes(bytes))"
        } else { speedText = bytes > 0 ? formatBytes(bytes) : "" }
        if let eta = json["etaSeconds"] as? NSNumber,
           let seconds = ProgressNumber.nonnegativeInt64(eta.doubleValue.rounded()), seconds < 31_536_000 {
            etaText = "约剩 \(formatDuration(Double(seconds)))"
        } else { etaText = "" }
        currentResource = json["currentResource"] as? String ?? ""
    }

    private func observePhoneImport(_ result: ScriptResult) {
        guard result.success, let raw = result.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let remote = json["remote"] as? String, remote.hasPrefix("RestoreInbox/"),
              let session = remote.split(separator: "/").last.map(String.init), UUID(uuidString: session) != nil else { return }
        importProgressTask?.cancel()
        importProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self, !self.busy else { return }
                let result = try? await self.executeScriptAsync("mac_control.py", arguments: ["read", "--bundle", self.bundleIdentifier, "--path", "Control/restore-progress.json"])
                guard !Task.isCancelled else { return }
                if let result, result.success, let raw = result.text.data(using: .utf8),
                   let value = TransferDisplay.decode(raw), value.direction == "IMPORT", value.sessionID == session {
                    self.progressText = value.label
                    self.progressFraction = value.progress.fraction
                    self.progressCountText = value.progress.countText
                    self.progressPercentText = value.progress.percentText
                    self.progressIndeterminate = value.total == 0
                    self.speedText = ""; self.etaText = ""; self.currentResource = ""
                    if value.finished { return }
                }
            }
        }
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = ProgressNumber.nonnegativeInt64(seconds.rounded()) ?? 0
        if total < 60 { return "\(total) 秒" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }

    nonisolated private static func executeScript(_ name: String, arguments: [String], cancelFile: URL? = nil) throws -> ScriptResult {
        let script = try scriptURL(name)
        let isControl = name == "mac_control.py" || (name == "usb_probe.py" && arguments.first == "discover")
        let result = try BoundedCommand.run(executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", script.path] + arguments, timeout: arguments.first == "heartbeat" ? 4 : isControl ? 30 : nil, cancelFile: cancelFile)
        if result.interruption == .timedOut { return ScriptResult(success: false, text: "iPhone 暂时没有回应。请解锁手机并打开 PhotoBridge 后重试。", terminalFailure: true) }
        if result.interruption == .cancelled { return ScriptResult(success: false, text: "已暂停，已保存的照片和进度保留。重新连接后可继续。") }
        if result.truncated { return ScriptResult(success: false, text: "返回的信息过多，已停止显示。原照片不受影响，请重新操作。", terminalFailure: true) }
        let text = String(data: result.output, encoding: .utf8) ?? "暂时无法读取结果，请重试。"
        return ScriptResult(success: result.exitCode == 0, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
    static let macConnectedFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.12, green: 0.29, blue: 0.19, alpha: 1) : NSColor(red: 0.79, green: 0.94, blue: 0.83, alpha: 1) })
    static let macConnectedInk = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.69, green: 0.94, blue: 0.76, alpha: 1) : NSColor(red: 0.10, green: 0.35, blue: 0.19, alpha: 1) })
    static let macBridgeBlue = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.65, green: 0.76, blue: 0.82, alpha: 1) : NSColor(red: 0.28, green: 0.39, blue: 0.46, alpha: 1) })
    static let macBridgeSky = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .windowBackgroundColor : NSColor(red: 0.965, green: 0.972, blue: 0.976, alpha: 1) })
    static let macBridgeInk = Color(nsColor: .labelColor)
    static let macBridgeMuted = Color(nsColor: .secondaryLabelColor)
    static let macBridgeButtonFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.21, green: 0.28, blue: 0.32, alpha: 1) : NSColor(red: 0.87, green: 0.91, blue: 0.93, alpha: 1) })
}

struct MacSoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 36)
            .foregroundStyle(primary ? Color.macBridgeBlue : Color.macBridgeInk)
            .background(primary ? Color.macBridgeButtonFill : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(color: .black.opacity(enabled && !configuration.isPressed ? 0.055 : 0.015), radius: 5, y: 2)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

private struct MacCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

private struct MacTransferScreen: View {
    @ObservedObject var transfer: MacTransferModel
    @State private var exportOptions = false
    @State private var importOptions = false
    private var connected: Bool { transfer.usbState == "已连接" }
    private var working: Bool { transfer.busy || transfer.loadingAlbums }
    var body: some View {
        ZStack {
            Color.macBridgeSky.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("照片传输").font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.macBridgeInk)
                        Spacer()
                        Menu {
                            Button("打开相册文件夹…") { transfer.chooseSavedAlbum() }
                            if transfer.savedFolder != nil {
                                Button("在 Finder 中显示") { transfer.openSavedFolder() }
                            }
                        } label: { Label("已保存的照片", systemImage: "photo.on.rectangle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").font(.title2).foregroundStyle(Color.macBridgeBlue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connected ? "iPhone 已连接" : "正在等待 iPhone").font(.headline)
                            Text(transfer.connectionMessage)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(connected ? "已连接" : "自动连接中", systemImage: connected ? "checkmark.circle.fill" : "cable.connector")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(connected ? Color.macConnectedInk : Color.macBridgeMuted)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(connected ? Color.macConnectedFill : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("connectionStatus")
                    }
                    if transfer.busy || !transfer.progressText.isEmpty { progress }
                    HStack(alignment: .top, spacing: 20) {
                        MacCard { exportControls }.frame(maxWidth: .infinity)
                        MacCard { importControls }.frame(maxWidth: .infinity)
                    }
                    if !transfer.userMessage.isEmpty && !transfer.userMessage.hasPrefix("还没有连接 iPhone") {
                        Text(transfer.userMessage).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if transfer.savedFolder != nil && !working {
                        HStack(spacing: 12) {
                            Button("查看已保存照片") { transfer.viewSavedAlbum() }.buttonStyle(MacSoftButtonStyle())
                        }
                    }
                    Text("按原相册顺序传输，原照片不会删除。").font(.caption).foregroundStyle(.secondary)
                }.padding(32).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
        .sheet(isPresented: $transfer.showAlbum) { SavedAlbumView(model: transfer) }
        .onAppear { transfer.startConnectionMonitoring() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in transfer.invalidateConnection() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in transfer.invalidateConnection() }
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出到 Mac").font(.title2.weight(.semibold))
            if !transfer.albums.isEmpty {
                Picker("相册", selection: $transfer.selectedAlbumID) {
                    ForEach(transfer.albums) { Text("\($0.name) · \($0.count.formatted()) 张").tag($0.id) }
                }.pickerStyle(.menu).controlSize(.large).disabled(working)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(transfer.loadingAlbums ? "正在读取相册…" : "连接后，你的相册会显示在这里。")
                    .foregroundStyle(.secondary).padding(.vertical, 8)
            }
            Button {
                if transfer.selectedAlbumID.isEmpty { transfer.refreshAlbums() }
                else { transfer.startMacExport() }
            } label: {
                HStack {
                    if transfer.loadingAlbums { ProgressView().controlSize(.small) }
                    else { Image(systemName: connected ? "arrow.down.to.line" : "iphone") }
                    Text(connected && transfer.selectedAlbumID.isEmpty ? "读取相册" : "选择保存位置并导出")
                }.frame(maxWidth: .infinity)
            }.buttonStyle(MacSoftButtonStyle(primary: true)).disabled(working || !connected)
            DisclosureGroup("更多选项", isExpanded: $exportOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("需要时从 iCloud 获取原图", isOn: $transfer.allowCloudDownload).disabled(working)
                    HStack(spacing: 12) {
                        Button("刷新相册") { transfer.refreshAlbums() }.disabled(working || !connected)
                        Button("继续未完成的导出") { transfer.continueMacExport() }.disabled(working || transfer.albums.isEmpty)
                    }.buttonStyle(MacSoftButtonStyle())
                }.padding(.top, 14)
            }.font(.subheadline).tint(.macBridgeBlue)
        }
    }
    private var importControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导入到 iPhone").font(.title2.weight(.semibold))
            Text("选择 PhotoBridge 保存的完整相册文件夹。发送后，在 iPhone 确认导入到新相册。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                transfer.uploadBackup()
            } label: {
                Label("选择文件夹并发送", systemImage: "arrow.up.to.line")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(MacSoftButtonStyle(primary: true)).disabled(working || !connected)
            DisclosureGroup("继续上次任务", isExpanded: $importOptions) {
                Button("选择未完成的发送") { transfer.resumeUpload() }
                    .buttonStyle(MacSoftButtonStyle()).disabled(working || !connected).padding(.top, 12)
            }.font(.subheadline).tint(.macBridgeBlue)
        }
    }
    private var progress: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(transfer.progressText).font(.headline)
                    Spacer()
                    Text(transfer.progressPercentText).font(.title2.weight(.semibold)).foregroundStyle(Color.macBridgeBlue)
                }
                Text(transfer.progressCountText).font(.title3).monospacedDigit()
                if transfer.progressIndeterminate { ProgressView().controlSize(.small) }
                else { ProgressView(value: transfer.progressFraction).tint(.macBridgeBlue) }
                HStack {
                    Text(transfer.speedText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(transfer.etaText).font(.caption).foregroundStyle(.secondary)
                    if transfer.busy { Button("暂停") { transfer.requestCancel() }.buttonStyle(MacSoftButtonStyle()) }
                }
                if !transfer.currentResource.isEmpty {
                    Text(transfer.currentResource).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

@main
struct PhotoBridgeMacApp: App {
    @StateObject private var transfer = MacTransferModel()
    var body: some Scene {
        WindowGroup("PhotoBridge") { MacTransferScreen(transfer: transfer) }
    }
}
