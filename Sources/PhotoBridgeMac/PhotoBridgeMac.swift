import AppKit
import PhotoBridgeCore
import Foundation
import ImageCaptureCore
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

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
    @Published var elapsedText = ""
    @Published var currentResource = ""
    @Published var recentBackups: [String] = []
    @Published var backupPreview: [BackupAssetPreview] = []
    @Published var albums: [RemoteAlbum] = []
    @Published var selectedAlbumID = ""
    @Published var remoteStageText = ""
    @Published var loadingAlbums = false
    @Published var progressIndeterminate = true
    @Published var savedFolder: URL?
    @Published var exportFolderName = ""
    @Published var importFolder: URL?
    @Published var importPreview: [BackupAssetPreview] = []
    @Published var importOrderNames: [String] = []
    @Published var loadingImportPreview = false
    @Published var allowCloudDownload = false
    @Published var showAlbum = false
    @Published var savedAlbumName = "已保存的相册"
    @Published var loadingPreview = false
    @Published var previewError = ""
    @Published var resumableDirection: String?
    @Published var completedSuccessfully = false
    private var previewTask: Task<(String, [BackupAssetPreview]), Error>?
    private var pendingExportTask: Task<Void, Never>?
    private var pendingUploadTask: Task<Void, Never>?
    private var activeExportRequestID: String?
    private var connectionTask: Task<Void, Never>?
    private var connectionFreshness = ConnectionFreshness()
    private var importPreviewTask: Task<Void, Never>?
    private var importPreviewGeneration = UUID()
    private var directTerminalSession: String?
    private var directTerminalPhase: String?
    private var directScriptSession: String?
    private var lastDisplayedProgress: PhotoProgress?
    private var displayProgress = ProgressDisplayState()
    private var displayOperationID = ""
    private var connectionGeneration = UUID()

    private let bundleIdentifier = "com.photobridge.OrderProbe"
    private var progressTask: Task<Void, Never>?
    private var importProgressTask: Task<Void, Never>?
    private var automaticImportSessions = Set<String>()
    private var overallStartedAt: Date?
    private var controlFile: URL?

    private func resetCompletion() {
        completedSuccessfully = false
    }

    init() {
        recentBackups = UserDefaults.standard.stringArray(forKey: "PhotoBridge.recentBackups") ?? []
        resumableDirection = UserDefaults.standard.string(forKey: "PhotoBridge.resumableDirection")
        if let path = recentBackups.first, FileManager.default.fileExists(atPath: path) { savedFolder = URL(fileURLWithPath: path) }
        if let path = UserDefaults.standard.string(forKey: "PhotoBridge.lastImportFolder"),
           FileManager.default.fileExists(atPath: path) { importFolder = URL(fileURLWithPath: path) }
    }

    private func setResumableDirection(_ value: String?) {
        resumableDirection = value
        if let value { UserDefaults.standard.set(value, forKey: "PhotoBridge.resumableDirection") }
        else { UserDefaults.standard.removeObject(forKey: "PhotoBridge.resumableDirection") }
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
            var failedHeartbeats = 0
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
                    failedHeartbeats = 0
                    if self.usbState != "已连接" { needsAlbums = true }
                    confirmedNonce = nonce
                    self.connectionFreshness.confirm(now: ProcessInfo.processInfo.systemUptime)
                    self.usbState = "已连接"
                    self.connectionMessage = "已准备好，可以开始传照片"
                } else {
                    failedHeartbeats += 1
                    if failedHeartbeats < 3 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    confirmedNonce = nil
                    self.connectionFreshness.invalidate()
                    self.usbState = "等待连接"
                    self.connectionMessage = value?["status"] as? String == "PHONE_NOT_READY"
                        ? "请解锁 iPhone 并打开 PhotoBridge。"
                        : "请连接数据线并打开 PhotoBridge。"
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
                    if !loaded.contains(where: { $0.id == self.selectedAlbumID }) {
                        self.selectedAlbumID = loaded.first?.id ?? ""
                        self.exportFolderName = loaded.first.map { ExportFolderName.sanitize($0.name) } ?? ""
                    }
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
        resetCompletion()
        guard let album = albums.first(where: { $0.id == selectedAlbumID }) else { userMessage = "请先选择一个相册。"; return }
        guard let parent = previous?.deletingLastPathComponent() ?? chooseDirectory(title: "选择照片保存位置") else { return }
        let requestID = existingRequestID ?? UUID().uuidString
        // A continuation always writes to a new sibling. The previous folder
        // is the source of truth; an editable name must never redirect it back
        // onto the old directory or an unrelated existing backup.
        let requestedName: String
        if let previous {
            requestedName = ExportFolderName.continuationName(for: previous.lastPathComponent)
        } else {
            requestedName = exportFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? album.name : exportFolderName
        }
        let folderName = ExportFolderName.sanitize(requestedName)
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            userMessage = "文件夹“\(folderName)”已经存在，请换一个名称。"
            return
        }
        rememberBackup(folder)
        savedFolder = folder
        busy = true; progressIndeterminate = true; progressFraction = 0
        setResumableDirection("TO_MAC")
        progressIndeterminate = true
        progressText = "正在连接 iPhone…"; speedText = ""; etaText = ""; currentResource = ""
        userMessage = "保存位置：\(folder.path)"
        activeExportRequestID = requestID
        let allowNetwork = allowCloudDownload
        pendingExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                if existingRequestID == nil {
                    var command: [String: Any] = ["id": requestID, "kind": "startExport", "albumIdentifier": album.id, "allowNetwork": allowNetwork, "fast": true]
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
                    self.setResumableDirection(result.success ? nil : "TO_MAC")
                    self.completedSuccessfully = result.success
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
                setResumableDirection("TO_MAC")
                userMessage = error is CancellationError ? "已暂停，原照片不受影响。" : "导出没有完成：\(error.localizedDescription)"
            }
        }
    }

    func continueMacExport() {
        guard !busy && !loadingAlbums else { return }
        resetCompletion()
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
        setResumableDirection("TO_MAC")
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
                setResumableDirection("TO_MAC")
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
        setResumableDirection("TO_MAC")
        userMessage = "正在把照片保存到你选择的文件夹…"
        runScript("album_export.py", arguments: ["download", "--remote", "Exports/\(selectedSession)", "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.setResumableDirection(result.success ? nil : "TO_MAC")
            self?.completedSuccessfully = result.success
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
        setResumableDirection("TO_MAC")
        userMessage = "正在继续保存…"
        runScript("album_resume.py", arguments: ["--remote", "Exports/\(selectedSession)", "--from-directory", previous.path, "--local", folder.path, "--bundle", bundleIdentifier], progressFile: folder.appendingPathComponent("transfer-progress.json"), controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.setResumableDirection(result.success ? nil : "TO_MAC")
            self?.completedSuccessfully = result.success
            self?.userMessage = result.success ? "已保存到：\(folder.path)" : "继续保存没有完成，请重试。"
            if result.success { self?.loadPreview(from: folder) }
        }
    }

    func uploadBackup() {
        guard !busy && !loadingAlbums else { return }
        guard let directory = importFolder else {
            chooseImportFolder()
            return
        }
        resetCompletion()
        userMessage = "正在发送照片到 iPhone…"
        overallStartedAt = Date()
        setResumableDirection("TO_IPHONE")
        let identity = UUID().uuidString
        let progressFile = uploadProgressFile(in: directory, identity: identity)
        watchUploadSession(progressFile, title: directory.lastPathComponent)
        runScript("upload_resume.py", arguments: ["--local", directory.path, "--journal-id", identity, "--stream-import"],
                  progressFile: progressFile, controlFile: makeControlFile()) { [weak self] result in
            self?.output = result.text
            self?.setResumableDirection("TO_IPHONE")
            self?.observePhoneImport(result)
            guard let self else { return }
            if result.success {
                self.importFolder = nil
                self.importPreview = []
                self.importOrderNames = []
                UserDefaults.standard.removeObject(forKey: "PhotoBridge.lastImportFolder")
                self.userMessage = "文件已发送，正在写入 iPhone 照片…"
                if let session = Self.restoreSession(from: result.text) {
                    Task { await self.startAutomaticImport(session: session, title: directory.lastPathComponent) }
                }
            } else {
                self.userMessage = "发送没有完成，请重新连接 iPhone 后重试。"
            }
        }
    }

    /// V4 direct path. One USB/House Arrest session streams all ordered files
    /// while the iPhone watcher commits each marker to PhotoKit immediately.
    /// The legacy inbox uploader and end-of-job verification are bypassed.
    func directImportFolder() {
        guard !busy, directScriptSession == nil, let directory = importFolder else { chooseImportFolder(); return }
        guard !loadingImportPreview else {
            userMessage = "正在读取 Mac 上看到的照片顺序，请稍候。"
            return
        }
        let orderedNames = importOrderNames.isEmpty ? importPreview.map { $0.mediaURL.lastPathComponent } : importOrderNames
        let supported = Self.orderedMediaURLs(in: directory, names: orderedNames)
        guard !supported.isEmpty else { userMessage = "文件夹里没有可导入的照片或视频。"; return }
        resetCompletion()
        busy = true; setResumableDirection("TO_IPHONE"); overallStartedAt = Date()
        directTerminalSession = nil
        directTerminalPhase = nil
        progressIndeterminate = false; progressFraction = 0; progressPercentText = "0%"
        progressCountText = "0 / \(supported.count.formatted()) 张已写入 iPhone"
        progressText = "正在导入 iPhone 照片"; elapsedText = ""; etaText = "正在计算剩余时间…"
        let session = UUID().uuidString
        directScriptSession = session
        let progressFile = directProgressFile(session: session)
        let orderFile = directOrderFile(session: session)
        try? FileManager.default.createDirectory(at: orderFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: supported.map(\.lastPathComponent), options: [.sortedKeys]) {
            try? data.write(to: orderFile, options: .atomic)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let requestID = UUID().uuidString
                try await self.sendControl(["id": requestID, "kind": "directStartSession", "sessionID": session,
                                            "title": directory.lastPathComponent, "total": supported.count], requestID: requestID)
                _ = try await self.waitForControlResponse(id: requestID)
                // runScript owns the streaming job state and requires an idle
                // model before it starts its bounded subprocess.
                self.busy = false
                self.watchDirectImport(session: session, total: supported.count)
                self.runScript("direct_batch.py", arguments: ["--local", directory.path, "--session", session,
                    "--order-file", orderFile.path], progressFile: progressFile, controlFile: self.makeControlFile(), keepImportProgress: true, preserveProgress: true) { [weak self] result in
                    guard let self else { return }
                    if result.success {
                        if self.directTerminalSession != session {
                            self.busy = true
                            self.progressText = "正在等待 iPhone 完成写入"
                        }
                    } else {
                        self.importProgressTask?.cancel()
                        self.importProgressTask = nil
                        self.busy = false
                        if self.directTerminalSession == session {
                            self.progressText = self.directTerminalPhase == "COMMITTED"
                                ? "已完成写入 iPhone 系统相册"
                                : "导入已暂停，进度已保留"
                        } else {
                            self.setResumableDirection("TO_IPHONE")
                            self.userMessage = "导入已暂停，已写入的照片会保留，可重新开始。"
                        }
                    }
                    self.directScriptSession = nil
                    try? FileManager.default.removeItem(at: orderFile)
                }
            } catch {
                self.busy = false; self.directScriptSession = nil
                self.setResumableDirection("TO_IPHONE"); self.userMessage = "导入没有开始：\(error.localizedDescription)"
                try? FileManager.default.removeItem(at: orderFile)
            }
        }
    }

    func chooseImportFolder() {
        guard !busy else { return }
        guard let directory = chooseDirectory(title: "选择要发送到 iPhone 的照片") else { return }
        importFolder = directory
        UserDefaults.standard.set(directory.path, forKey: "PhotoBridge.lastImportFolder")
        loadImportPreview(from: directory)
    }

    func refreshImportPreviewIfNeeded() {
        guard let directory = importFolder,
              FileManager.default.fileExists(atPath: directory.path),
              importPreview.isEmpty, !loadingImportPreview else { return }
        loadImportPreview(from: directory)
    }

    private func loadImportPreview(from directory: URL) {
        let generation = UUID()
        importPreviewGeneration = generation
        importPreview = []
        importOrderNames = []
        loadingImportPreview = true
        importPreviewTask?.cancel()
        importPreviewTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) { try Self.readPreview(from: directory) }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self?.importPreviewGeneration == generation, self?.importFolder == directory else { return }
                    self?.importPreview = result.1
                    self?.importOrderNames = result.1.map { $0.mediaURL.lastPathComponent }
                    self?.loadingImportPreview = false
                }
            } catch {
                await MainActor.run {
                    guard self?.importPreviewGeneration == generation else { return }
                    self?.importOrderNames = []
                    self?.loadingImportPreview = false
                }
            }
        }
    }

    func resumeUpload() {
        guard !busy && !loadingAlbums else { return }
        resetCompletion()
        let directory: URL
        if let importFolder { directory = importFolder }
        else {
            guard let chosen = chooseDirectory(title: "选择上次未完成的照片") else { return }
            directory = chosen
        }
        importFolder = directory
        loadImportPreview(from: directory)
        busy = true; progressIndeterminate = true; progressText = "正在查找上次发送记录…"
        pendingUploadTask = Task {
            guard !Task.isCancelled else {
                busy = false; pendingUploadTask = nil; userMessage = "已暂停，原照片不受影响。"; return
            }
            pendingUploadTask = nil; busy = false
            userMessage = "正在继续发送照片到 iPhone…"
            setResumableDirection("TO_IPHONE")
            let identity = UUID().uuidString
            runScript("upload_resume.py", arguments: ["--local", directory.path, "--auto-resume", "--journal-id", identity],
                      progressFile: uploadProgressFile(in: directory, identity: identity), controlFile: makeControlFile()) { [weak self] result in
                self?.output = result.text
                self?.setResumableDirection("TO_IPHONE")
                self?.observePhoneImport(result)
                guard let self else { return }
                if result.success {
                    self.importFolder = nil
                    self.importPreview = []
                    self.importOrderNames = []
                    UserDefaults.standard.removeObject(forKey: "PhotoBridge.lastImportFolder")
                    self.userMessage = "文件已发送，正在写入 iPhone 照片…"
                    if let session = Self.restoreSession(from: result.text) {
                        Task { await self.startAutomaticImport(session: session, title: directory.lastPathComponent) }
                    }
                } else {
                    self.userMessage = "继续发送没有完成，请重试。"
                }
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
        let knownBackup = FileManager.default.fileExists(atPath: folder.appendingPathComponent(".photobridge-layout.json").path)
            || (FileManager.default.fileExists(atPath: folder.appendingPathComponent("album-order.json").path)
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("transfer-manifest.json").path))
        if knownBackup {
            let directory = uploadJournalDirectory(in: folder)
            return directory.appendingPathComponent((directory == folder ? ".photobridge-upload-" : "") + identity + ".json")
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBridge/Progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("upload-\(identity).json")
    }

    private func directProgressFile(session: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBridge/DirectProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(session).json")
    }

    private func directOrderFile(session: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoBridge/DirectProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(session).order.json")
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

    nonisolated private static func orderedMediaURLs(in folder: URL, names: [String]) -> [URL] {
        let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "dng", "gif", "mov", "mp4", "m4v"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]))?.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true && supportedExtensions.contains(url.pathExtension.lowercased())
        } ?? []
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0) })
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy({ byName[$0] != nil }) else { return [] }
        return names.compactMap { byName[$0] }
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
            }.sorted { lhs, rhs in
                let left = Int(lhs.lastPathComponent.split(separator: "_", maxSplits: 1).first ?? "") ?? Int.max
                let right = Int(rhs.lastPathComponent.split(separator: "_", maxSplits: 1).first ?? "") ?? Int.max
                return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
            }.enumerated().map { index, url in
                BackupAssetPreview(id: index, ordinal: Int(url.lastPathComponent.split(separator: "_", maxSplits: 1)[0]) ?? index + 1,
                    primaryFilename: url.lastPathComponent, mediaURL: url)
            }
            return (title, photos)
        }
        let genericExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "raw", "cr2", "nef", "arw", "tif", "tiff", "gif", "webp", "mov", "mp4", "m4v"]
        let genericFiles = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true && genericExtensions.contains(url.pathExtension.lowercased())
            }
        let hasManifest = FileManager.default.fileExists(atPath: metadataURL(in: folder, name: "album-order.json").path)
        let hasRecords = FileManager.default.fileExists(atPath: folder.appendingPathComponent("asset-records").path)
        if !hasManifest && !hasRecords {
            let photos = genericFiles.enumerated().map { index, url in
                BackupAssetPreview(id: index, ordinal: index + 1, primaryFilename: url.lastPathComponent, mediaURL: url)
            }
            return (folder.lastPathComponent.isEmpty ? "Mac 照片" : folder.lastPathComponent, photos)
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
                           controlFile: URL? = nil, keepImportProgress: Bool = false,
                           preserveProgress: Bool = false,
                           completion: @escaping (ScriptResult) -> Void) {
        guard !busy else { return }
        busy = true
        if !keepImportProgress {
            importProgressTask?.cancel(); importProgressTask = nil
        }
        if !preserveProgress {
            progressCountText = ""; progressPercentText = "—"; elapsedText = ""
        }
        lastDisplayedProgress = nil
        displayProgress = ProgressDisplayState()
        displayOperationID = progressFile?.path ?? UUID().uuidString
        self.controlFile = controlFile
        if let controlFile { try? FileManager.default.removeItem(at: controlFile) }
        if !preserveProgress {
            progressFraction = 0
            progressIndeterminate = true
            progressText = "正在准备照片…"
            progressCountText = "准备完成后立即开始导入"
            speedText = ""
            etaText = ""
            currentResource = ""
        }
        startProgressPolling(file: progressFile)
        output = "正在执行 \(name)…"
        Task {
            let result = await Task.detached(priority: .utility) { () -> ScriptResult in
                do {
                    var commandArguments = arguments
                    if let controlFile { commandArguments += ["--cancel-file", controlFile.path] }
                    if ["upload_resume.py", "direct_batch.py"].contains(name), let progressFile {
                        commandArguments += ["--progress-file", progressFile.path]
                    }
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
        let direct = json["direction"] as? String == "TO_IPHONE" && json["kind"] as? String == "PhotoBridgeTransferDisplay"
        if direct {
            // The phone is the source of truth once PhotoKit writing starts.
            // The USB upload journal may finish earlier and must not replace
            // the live native Photos counter on the Mac UI.
            let session = json["sessionID"] as? String ?? ""
            if importProgressTask != nil || directTerminalSession == session { return }
            let done = count("completed")
            let expected = count("total")
            let finished = state == "COMMITTED" && expected > 0 && done == expected
            let candidate = PhotoProgress(completed: done, total: expected, finished: finished)
            _ = displayProgress.update(candidate, operationID: displayOperationID, phase: state)
            let progress = displayProgress.progress
            lastDisplayedProgress = progress
            progressIndeterminate = expected == 0
            progressFraction = progress.fraction
            progressCountText = expected > 0 ? "\(done.formatted()) / \(expected.formatted()) 张已发送" : "正在连接 iPhone…"
            progressPercentText = progress.percentText
            progressText = finished ? "已实时写入 iPhone 系统相册" : "正在发送并写入 iPhone 照片"
            let bytes = ProgressNumber.nonnegativeInt64((json["bytesCompleted"] as? NSNumber)?.doubleValue ?? 0) ?? 0
            if let elapsed = json["elapsedSeconds"] as? NSNumber,
               let safeElapsed = ProgressNumber.nonnegativeInt64(elapsed.doubleValue.rounded()) {
                elapsedText = "已用 \(formatDuration(Double(safeElapsed)))"
            }
            if let number = json["bytesPerSecond"] as? NSNumber,
               let speed = ProgressNumber.nonnegativeInt64(number.doubleValue), speed > 0 {
                speedText = "\(formatBytes(speed))/s · \(formatBytes(bytes))"
            } else { speedText = bytes > 0 ? formatBytes(bytes) : "" }
            if let eta = json["etaSeconds"] as? NSNumber,
               let seconds = ProgressNumber.nonnegativeInt64(eta.doubleValue.rounded()), seconds < 31_536_000 {
                etaText = "约剩 \(formatDuration(Double(seconds)))"
            } else { etaText = "" }
            currentResource = json["currentResource"] as? String ?? ""
            return
        }
        let uploading = (json["remote"] as? String ?? "").hasPrefix("RestoreInbox/") || resumableDirection == "TO_IPHONE"
        let assets = count("assetsVerified"), total = count("totalAssets")
        let verifying = state == "VERIFYING"
        let scanning = total == 0 && !verifying
        let done = verifying ? count("verificationCompleted") : (scanning ? count("scannedAssets") : assets)
        let expected = verifying ? count("verificationTotal") : (scanning ? count("scanTotalAssets") : total)
        let candidate = PhotoProgress(completed: done, total: expected,
            finished: ["COMMITTED", "USB_VERIFIED"].contains(state))
        let displayPhase = scanning ? "SCANNING" : state
        _ = displayProgress.update(candidate, operationID: displayOperationID, phase: displayPhase)
        let progress = displayProgress.progress
        lastDisplayedProgress = progress
        progressIndeterminate = expected == 0
        let scanComplete = scanning && expected > 0 && done == expected
        progressIndeterminate = expected == 0
        progressFraction = verifying ? 0.5 : (scanComplete ? 1 : progress.fraction)
        progressCountText = verifying ? "已发送，正在写入 iPhone 照片" : (scanning && uploading ? "已准备 \(done.formatted()) / \(expected.formatted()) 张" : (expected > 0 ? progress.countText : (scanning ? "已准备 \(done.formatted()) 张" : "正在读取照片…")))
        progressPercentText = verifying ? "50%" : (scanComplete ? "100%" : progress.percentText)
        if verifying { progressText = uploading ? "正在按顺序导入 iPhone 照片" : "正在核对照片" }
        else if scanComplete { progressText = uploading ? "正在按顺序导入 iPhone 照片" : "扫描完成，正在完成最后检查" }
        else if scanning { progressText = uploading ? "正在准备照片" : "正在读取照片" }
        else if state == "FINALIZING" { progressText = "正在完成最后检查" }
        else if state == "COMMITTED" { progressText = "已保存到 Mac" }
        else if state == "USB_VERIFIED" { progressText = "正在按顺序导入 iPhone 照片" }
        else if ["STOPPED", "FAILED"].contains(state) { progressText = "尚未完成，进度已保留" }
        else { progressText = uploading ? "正在导入 iPhone 照片" : "正在保存到 Mac" }
        if json["phoneInForeground"] as? Bool == false { progressText = "请回到 iPhone 的 PhotoBridge，继续准备照片" }
        let bytes = ProgressNumber.nonnegativeInt64((json["bytesVerified"] as? NSNumber)?.doubleValue ?? 0) ?? 0
        if let elapsed = json["elapsedSeconds"] as? NSNumber ?? json["seconds"] as? NSNumber,
           let safeElapsed = ProgressNumber.nonnegativeInt64(elapsed.doubleValue.rounded()) {
            elapsedText = "已用 \(formatDuration(Double(safeElapsed)))"
        }
        if let number = json["bytesPerSecond"] as? NSNumber,
           let speed = ProgressNumber.nonnegativeInt64(number.doubleValue), speed > 0 {
            speedText = "\(formatBytes(speed))/s · \(formatBytes(bytes))"
        } else { speedText = bytes > 0 ? formatBytes(bytes) : "" }
        if let eta = json["etaSeconds"] as? NSNumber,
           let seconds = ProgressNumber.nonnegativeInt64(eta.doubleValue.rounded()), seconds < 31_536_000 {
            etaText = "约剩 \(formatDuration(Double(seconds)))"
        } else { etaText = "" }
        currentResource = verifying ? "" : (json["currentResource"] as? String ?? "")
    }

    private func observePhoneImport(_ result: ScriptResult) {
        guard result.success, let raw = result.text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let remote = json["remote"] as? String, remote.hasPrefix("RestoreInbox/"),
              let session = remote.split(separator: "/").last.map(String.init), UUID(uuidString: session) != nil else { return }
        importProgressTask?.cancel()
        importProgressTask = Task { [weak self] in
            var missedReads = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                let result = try? await self.executeScriptAsync("mac_control.py", arguments: ["read", "--bundle", self.bundleIdentifier, "--path", "Control/restore-progress.json"])
                guard !Task.isCancelled else { return }
                if let result, result.success, let raw = result.text.data(using: .utf8),
                   let value = TransferDisplay.decode(raw), value.direction == "IMPORT", value.sessionID == session {
                    missedReads = 0
                    self.progressText = value.finished ? "已按顺序导入 iPhone 照片" : "正在按顺序导入 iPhone 照片"
                    _ = self.displayProgress.update(value.progress, operationID: "IMPORT:\(session)", phase: value.phase)
                    let progress = self.displayProgress.progress
                    self.lastDisplayedProgress = progress
                    let combined = value.finished ? 1 : 0.5 + progress.fraction * 0.5
                    self.progressFraction = combined
                    self.progressCountText = "\(value.completed.formatted()) / \(value.total.formatted()) 张已写入"
                    self.progressPercentText = value.finished ? "100%" : "\(Int(combined * 100))%"
                    self.progressIndeterminate = value.total == 0
                    let elapsed = self.overallStartedAt.map { Date().timeIntervalSince($0) } ?? value.elapsedSeconds ?? 0
                    self.elapsedText = "已用 \(self.formatDuration(max(0, elapsed)))"
                    self.speedText = ""
                    self.etaText = combined > 0 && combined < 1 ? "约剩 \(self.formatDuration(elapsed * (1 / combined - 1)))" : ""
                    self.currentResource = ""
                    if value.finished {
                        self.completedSuccessfully = true
                        self.setResumableDirection(nil)
                        self.userMessage = "照片已全部写入 iPhone 系统相册"
                        return
                    }
                } else {
                    missedReads += 1
                    if missedReads >= 1_200 { return } // 30 minutes without a phone progress record.
                }
            }
        }
    }

    private static func restoreSession(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let remote = json["remote"] as? String,
              remote.hasPrefix("RestoreInbox/"),
              let session = remote.split(separator: "/").last.map(String.init),
              UUID(uuidString: session) != nil else { return nil }
        return session
    }

    private func startAutomaticImport(session: String, title: String) async -> Bool {
        guard !automaticImportSessions.contains(session) else { return true }
        progressText = "正在按顺序导入 iPhone 照片"
        progressFraction = 0.5
        progressPercentText = "50%"
        etaText = "正在计算剩余时间…"
        let requestID = UUID().uuidString
        do {
            _ = try await sendControl(["id": requestID, "kind": "startImport",
                                       "sessionID": session, "title": title], requestID: requestID)
            automaticImportSessions.insert(session)
            return true
        } catch {
            userMessage = "文件已发送，但 iPhone 未能自动写入照片；请打开 iPhone 的导入页面继续。"
            return false
        }
    }

    private func watchUploadSession(_ progressFile: URL, title: String) {
        Task { [weak self] in
            for _ in 0..<1_800 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let data = try? Data(contentsOf: progressFile),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let remote = json["remote"] as? String,
                      remote.hasPrefix("RestoreInbox/"),
                      let session = remote.split(separator: "/").last.map(String.init),
                      UUID(uuidString: session) != nil else { continue }
                if await self.startAutomaticImport(session: session, title: title) { return }
            }
        }
    }

    private func watchDirectImport(session: String, total: Int) {
        importProgressTask?.cancel()
        importProgressTask = Task { [weak self] in
            var missedReads = 0
            for _ in 0..<1_800 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                let result = try? await self.executeScriptAsync("mac_control.py", arguments: [
                    "read", "--bundle", self.bundleIdentifier, "--path", "Control/direct-import-progress.json"
                ])
                guard !Task.isCancelled else { return }
                if let result, result.success, let raw = result.text.data(using: .utf8),
                   let value = TransferDisplay.decode(raw), value.direction == "IMPORT", value.sessionID == session {
                    missedReads = 0
                    _ = self.displayProgress.update(value.progress, operationID: "DIRECT:\(session)", phase: value.phase)
                    let progress = self.displayProgress.progress
                    self.lastDisplayedProgress = progress
                    self.progressIndeterminate = value.total == 0
                    self.progressFraction = progress.fraction
                    self.progressCountText = "\(value.completed.formatted()) / \(total.formatted()) 张已写入 iPhone"
                    self.progressPercentText = progress.percentText
                    self.progressText = value.finished ? "已完成写入 iPhone 系统相册" : value.phase == "VERIFYING" ? "正在确认相册顺序" : "正在写入 iPhone 系统相册"
                    let elapsed = self.overallStartedAt.map { Date().timeIntervalSince($0) } ?? value.elapsedSeconds ?? 0
                    self.elapsedText = "已用 \(self.formatDuration(max(0, elapsed)))"
                    self.currentResource = ""
                    self.speedText = ""
                    if value.finished {
                        self.etaText = ""
                    } else if progress.fraction > 0, elapsed > 0 {
                        let remaining = elapsed * (1 / progress.fraction - 1)
                        self.etaText = "约剩 \(self.formatDuration(remaining))"
                    } else {
                        self.etaText = "正在估算剩余时间…"
                    }
                    if value.finished {
                        self.completedSuccessfully = true
                        self.directTerminalSession = session
                        self.directTerminalPhase = value.phase
                        self.busy = self.directScriptSession == session
                        self.setResumableDirection(nil)
                        self.userMessage = "照片已全部写入 iPhone 系统相册。"
                        self.importProgressTask = nil
                        return
                    }
                    if value.phase == "FAILED" {
                        self.directTerminalSession = session
                        self.directTerminalPhase = value.phase
                        self.busy = self.directScriptSession == session
                        self.setResumableDirection("TO_IPHONE")
                        self.userMessage = "iPhone 写入没有完成，已写入的照片会保留。"
                        self.importProgressTask = nil
                        return
                    }
                } else {
                    missedReads += 1
                    if missedReads >= 120 {
                        self.directTerminalSession = session
                        self.directTerminalPhase = "FAILED"
                        self.busy = self.directScriptSession == session
                        self.setResumableDirection("TO_IPHONE")
                        self.userMessage = "等待 iPhone 写入超时，进度已保留，可重新连接后继续。"
                        self.importProgressTask = nil
                        return
                    }
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
    static let macBridgeBlue = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.62, green: 0.86, blue: 0.70, alpha: 1) : NSColor(red: 0.11, green: 0.34, blue: 0.24, alpha: 1) })
    static let macBridgeSky = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.07, green: 0.10, blue: 0.09, alpha: 1) : NSColor.white })
    static let macBridgeInk = Color(nsColor: .labelColor)
    static let macBridgeMuted = Color(nsColor: .secondaryLabelColor)
    static let macBridgeButtonFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.13, green: 0.28, blue: 0.20, alpha: 1) : NSColor(red: 0.88, green: 0.95, blue: 0.91, alpha: 1) })
    static let macBridgeProgressFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.12, green: 0.18, blue: 0.22, alpha: 1) : NSColor(red: 0.985, green: 0.992, blue: 0.998, alpha: 1) })
    static let macExport = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.58, green: 0.84, blue: 0.68, alpha: 1) : NSColor(red: 0.10, green: 0.36, blue: 0.25, alpha: 1) })
    static let macExportFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.11, green: 0.25, blue: 0.18, alpha: 1) : NSColor(red: 0.88, green: 0.95, blue: 0.90, alpha: 1) })
    static let macImport = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.74, green: 0.88, blue: 0.62, alpha: 1) : NSColor(red: 0.31, green: 0.45, blue: 0.21, alpha: 1) })
    static let macImportFill = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.22, green: 0.31, blue: 0.14, alpha: 1) : NSColor(red: 0.92, green: 0.95, blue: 0.84, alpha: 1) })
}

struct MacSoftButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    var tint: Color = .macBridgeBlue
    var fill: Color?
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let foreground = primary ? (enabled ? tint : tint.opacity(0.42)) : Color.macBridgeInk
        let tintOpacity = enabled ? (configuration.isPressed ? 0.22 : 0.14) : 0.06
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 36)
            .foregroundStyle(foreground)
            .background(.regularMaterial, in: shape)
            .background(primary ? tint.opacity(tintOpacity) : Color(nsColor: .controlBackgroundColor).opacity(0.66), in: shape)
            .overlay(shape.stroke(primary ? tint.opacity(enabled ? 0.32 : 0.12) : Color.white.opacity(0.72), lineWidth: 1))
            .shadow(color: tint.opacity(enabled && !configuration.isPressed ? 0.13 : 0.03), radius: 7, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct MacDirectionLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .shadow(color: tint.opacity(0.25), radius: 3)
            Label(title, systemImage: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.macBridgeInk)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MacCompletionBadge: View {
    let title: String
    let subtitle: String
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.macConnectedFill)
                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.macConnectedInk)
            }
            .frame(width: 34, height: 34)
            .scaleEffect(visible ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { visible = true }
        }
    }
}

private struct MacCard<Content: View>: View {
    let content: Content
    let emphasis: Bool
    let tint: Color?
    init(emphasis: Bool = false, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.emphasis = emphasis
        self.tint = tint
        self.content = content()
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: shape)
            .background(Color.white.opacity(emphasis ? 0.52 : 0.44), in: shape)
            .overlay(shape.stroke(emphasis ? Color.macBridgeBlue.opacity(0.20) : Color.white.opacity(0.72), lineWidth: 1))
            .shadow(color: .black.opacity(emphasis ? 0.08 : 0.05), radius: emphasis ? 16 : 12, y: emphasis ? 7 : 5)
    }
}

private struct MacBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(red: 0.95, green: 0.975, blue: 0.99, alpha: 1)),
                    Color(nsColor: NSColor(red: 0.985, green: 0.995, blue: 0.98, alpha: 1)),
                    Color(nsColor: NSColor(red: 0.94, green: 0.97, blue: 0.955, alpha: 1))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(nsColor: NSColor(red: 0.63, green: 0.86, blue: 0.75, alpha: 0.16)), .clear],
                center: .topLeading,
                startRadius: 16,
                endRadius: 520
            )
            RadialGradient(
                colors: [Color(nsColor: NSColor(red: 0.69, green: 0.80, blue: 0.98, alpha: 0.10)), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

private struct MacTransferScreen: View {
    @ObservedObject var transfer: MacTransferModel
    @State private var exportOptions = false
    @State private var thumbnailRatio: ThumbnailRatio = .square
    private var connected: Bool { transfer.usbState == "已连接" }
    private var working: Bool { transfer.busy || transfer.loadingAlbums || transfer.loadingImportPreview }
    var body: some View {
        ZStack {
            MacBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.macBridgeButtonFill)
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.macBridgeBlue)
                        }.frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("照片传输").font(.system(size: 28, weight: .semibold)).foregroundStyle(Color.macBridgeInk)
                            Text("在 iPhone 和 Mac 之间保存照片")
                                .font(.subheadline).foregroundStyle(Color.macBridgeMuted)
                        }
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
                            Text(connected ? "保持 PhotoBridge 打开即可" : transfer.connectionMessage)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(connected ? "已连接" : "自动连接中", systemImage: connected ? "checkmark.circle.fill" : "cable.connector")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(connected ? Color.macConnectedInk : Color.macBridgeMuted)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(connected ? Color.macConnectedFill : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                            .scaleEffect(connected ? 1 : 0.99)
                            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: connected)
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
                    HStack {
                        Text("按原相册顺序传输，原照片不会删除。").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("v1.0.0").font(.caption2.monospacedDigit()).foregroundStyle(Color.macBridgeMuted)
                    }
                }.padding(32).frame(maxWidth: 1080, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 1120, height: 760)
        .animation(.easeOut(duration: 0.22), value: transfer.busy)
        .sheet(isPresented: $transfer.showAlbum) { SavedAlbumView(model: transfer) }
        .onAppear {
            transfer.startConnectionMonitoring()
            transfer.refreshImportPreviewIfNeeded()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in transfer.invalidateConnection() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in transfer.invalidateConnection() }
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacDirectionLabel(title: "保存到 Mac", systemImage: "arrow.down.to.line", tint: .macExport)
            Text("把 iPhone 相册保存到 Mac")
                .font(.subheadline).foregroundStyle(Color.macBridgeMuted)
            if !transfer.albums.isEmpty {
                Picker("相册", selection: $transfer.selectedAlbumID) {
                    ForEach(transfer.albums) { Text("\($0.name) · \($0.count.formatted()) 张").tag($0.id) }
                }.pickerStyle(.menu).controlSize(.large).disabled(working)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: transfer.selectedAlbumID) { selected in
                        if let album = transfer.albums.first(where: { $0.id == selected }) {
                            transfer.exportFolderName = ExportFolderName.sanitize(album.name)
                        }
                    }
                TextField("导出文件夹名称", text: $transfer.exportFolderName)
                    .textFieldStyle(.roundedBorder).disabled(working)
                    .help("照片会直接保存到这个文件夹，文件夹内不再创建子文件夹")
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
            }.buttonStyle(MacSoftButtonStyle(primary: true, tint: .macExport, fill: .macExportFill)).disabled(working || !connected)
            if transfer.resumableDirection == "TO_MAC" {
                Button("继续上次导出") { transfer.continueMacExport() }
                    .buttonStyle(MacSoftButtonStyle())
                    .disabled(working || !connected)
            }
            DisclosureGroup("更多选项", isExpanded: $exportOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("需要时从 iCloud 获取原图", isOn: $transfer.allowCloudDownload).disabled(working)
                    HStack(spacing: 12) {
                        Button("刷新相册") { transfer.refreshAlbums() }.disabled(working || !connected)
                    }.buttonStyle(MacSoftButtonStyle())
                }.padding(.top, 14)
            }.font(.subheadline).tint(.macBridgeBlue)
        }
    }
    private var importControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            MacDirectionLabel(title: "导入到 iPhone", systemImage: "arrow.up.to.line", tint: .macImport)
            Text("按 Mac 当前顺序逐张写入 iPhone 系统照片")
                .font(.subheadline).foregroundStyle(Color.macBridgeMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let folder = transfer.importFolder {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.macImport)
                    Text(folder.lastPathComponent).font(.headline).lineLimit(1)
                    Spacer()
                    Button("更换") { transfer.chooseImportFolder() }.buttonStyle(MacSoftButtonStyle())
                }
                FolderThumbnailGrid(photos: transfer.importPreview, loading: transfer.loadingImportPreview,
                                    emptyText: "这个文件夹里还没有可预览的照片",
                                    ratio: thumbnailRatio)
                if !transfer.importPreview.isEmpty {
                    Text("文件夹内共 \(transfer.importPreview.count.formatted()) 张照片")
                        .font(.caption.monospacedDigit()).foregroundStyle(Color.macBridgeMuted)
                }
            }
            Button {
                if transfer.importFolder == nil { transfer.chooseImportFolder() } else { transfer.directImportFolder() }
            } label: {
                Label(transfer.importFolder == nil ? "选择文件夹" : "开始导入到 iPhone", systemImage: "arrow.up.to.line")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(MacSoftButtonStyle(primary: true, tint: .macImport, fill: .macImportFill)).disabled(working || !connected)
            if transfer.resumableDirection == "TO_IPHONE" {
                Button("继续上次发送") { transfer.resumeUpload() }
                    .buttonStyle(MacSoftButtonStyle())
                    .disabled(working || !connected)
            }
            if transfer.resumableDirection != "TO_IPHONE" {
                Text("按当前预览顺序导入，文件名保持不变")
                    .font(.caption).foregroundStyle(Color.macBridgeMuted)
            }
        }
    }
    private var progress: some View {
        MacCard(emphasis: true) {
            VStack(alignment: .leading, spacing: 14) {
                if transfer.completedSuccessfully {
                    MacCompletionBadge(title: "已完成", subtitle: "照片已保存到目标位置")
                }
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(transfer.progressIndeterminate ? Color.macBridgeBlue : Color.macConnectedInk)
                            .frame(width: 8, height: 8)
                        Text(transfer.progressText).font(.headline)
                    }
                    Spacer()
                    if #available(macOS 14.0, *) {
                        Text(transfer.progressPercentText).font(.title2.weight(.semibold)).foregroundStyle(Color.macBridgeBlue)
                            .frame(width: 60, alignment: .trailing).monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.18), value: transfer.progressPercentText)
                    } else {
                        Text(transfer.progressPercentText).font(.title2.weight(.semibold)).foregroundStyle(Color.macBridgeBlue)
                            .frame(width: 60, alignment: .trailing).monospacedDigit()
                            .animation(.easeOut(duration: 0.18), value: transfer.progressPercentText)
                    }
                }
                if #available(macOS 14.0, *) {
                    Text(transfer.progressCountText).font(.title3).monospacedDigit()
                        .frame(width: 190, alignment: .leading)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.18), value: transfer.progressCountText)
                } else {
                    Text(transfer.progressCountText).font(.title3).monospacedDigit()
                        .frame(width: 190, alignment: .leading)
                        .animation(.easeOut(duration: 0.18), value: transfer.progressCountText)
                }
                if transfer.progressIndeterminate { ProgressView().controlSize(.small) }
                else {
                    ProgressView(value: transfer.progressFraction)
                        .tint(.macBridgeBlue)
                        .animation(.linear(duration: 0.32), value: transfer.progressFraction)
                }
                HStack {
                    Text(transfer.speedText).font(.caption).foregroundStyle(.secondary)
                    if !transfer.elapsedText.isEmpty { Text(transfer.elapsedText).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer()
                    Text(transfer.etaText).font(.caption).foregroundStyle(.secondary)
                    if transfer.busy { Button("暂停") { transfer.requestCancel() }.buttonStyle(MacSoftButtonStyle()) }
                }
                if !transfer.currentResource.isEmpty && !transfer.progressText.contains("导入 iPhone") {
                    Text(transfer.currentResource).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !transfer.busy, let direction = transfer.resumableDirection, !transfer.progressText.contains("导入 iPhone") {
                    Button(direction == "TO_IPHONE" ? "继续发送上次任务" : "继续上次导出") {
                        if direction == "TO_IPHONE" { transfer.resumeUpload() }
                        else { transfer.continueMacExport() }
                    }
                    .buttonStyle(MacSoftButtonStyle(primary: true))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .defaultSize(width: 1120, height: 760)
            .windowResizability(.contentSize)
    }
}
