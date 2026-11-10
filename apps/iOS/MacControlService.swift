import Foundation
import Photos
import SwiftUI
import UIKit
import PhotoBridgeCore

/// Request-scoped USB control. Only an open, authorized phone app reads Photos.
/// Accepted requests are recorded before work and never replayed after relaunch.
@MainActor
final class MacControlService: ObservableObject {
    struct AutomaticImportRequest: Equatable {
        let sessionID: String
        let title: String
    }
    let exporter = OriginalExportService()
    let directImporter = NativePhotoImportService()
    @Published var active = false { didSet { updateIdleTimer() } }
    @Published var message = "在 Mac 上选择相册和保存位置即可开始"
    @Published var completed = 0
    @Published var total = 0
    @Published var macProgress: TransferDisplay?
    @Published private(set) var directProgress: DirectImportProgress?
    @Published var automaticImportRequest: AutomaticImportRequest?
    @Published private(set) var restoreInProgress = false
    @Published private(set) var connected = false
    var preparationProgress: PhotoProgress { PhotoProgress(completed: completed, total: total, finished: false) }
    var exportDisplay: TransferDisplay? {
        guard let macProgress, !active || macProgress.operationID == activeRequestID else { return nil }
        return macProgress
    }
    private var acknowledged: Set<String> = []
    private var lastJob: Data?
    private var phoneInForeground = true
    private var loop: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connection = PhoneConnection()
    private var activeRequestID: String?
    private var albumIdentifier = ""
    private var macDisplayState = ProgressDisplayState()
    private var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Control", isDirectory: true)
    }

    init() {
        directImporter.onProgress = { [weak self] value in
            self?.publishDirectProgress(value)
        }
    }

    func start() {
        guard loop == nil else { return }
        do {
            for name in ["Requests", "Responses", "Jobs"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
        } catch { message = "无法准备连接，请重新打开 App"; return }
        let controlRoot = root
        // Separate from album enumeration so slow PhotoKit work cannot block it.
        heartbeatTask = Task { [weak self] in
            var lastReply: ConnectionReply?
            while !Task.isCancelled {
                let request = await Task.detached(priority: .utility) { ConnectionRequest.read(in: controlRoot) }.value
                guard let self, !Task.isCancelled else { return }
                if let request {
                    let reply = self.connection.receive(request, now: ProcessInfo.processInfo.systemUptime, foreground: self.phoneInForeground)
                    if reply != lastReply {
                        do {
                            try await Task.detached(priority: .utility) { try reply.write(in: controlRoot) }.value
                            lastReply = reply
                        } catch { self.connection.invalidate() }
                    }
                }
                let ready = self.phoneInForeground && self.connection.isConnected(now: ProcessInfo.processInfo.systemUptime)
                if self.connected != ready { self.connected = ready }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        loop = Task { [weak self] in
            await Task.detached(priority: .utility) { Self.recoverJobs(in: controlRoot) }.value
            while !Task.isCancelled {
                await self?.pollOnce()
                if let self, !self.directProgressIsActive {
                    let url = self.root.appendingPathComponent("transfer-progress.json")
                    let value = await Task.detached(priority: .utility) { TransferDisplay.read(at: url) }.value
                    guard !Task.isCancelled else { return }
                    if let value {
                        _ = self.macDisplayState.update(value.progress, operationID: value.operationID, phase: value.phase)
                        let progress = self.macDisplayState.progress
                        let display = TransferDisplay(operationID: value.operationID, direction: value.direction,
                            phase: value.phase, completed: progress.completed, total: progress.total,
                            sessionID: value.sessionID, updatedAt: value.updatedAt, elapsedSeconds: value.elapsedSeconds)
                        if self.macProgress != display { self.macProgress = display }
                    }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private var directProgressIsActive: Bool { directProgress?.isActive == true }

    private func publishDirectProgress(_ value: DirectImportProgress) {
        directProgress = value
        let display = TransferDisplay(operationID: value.sessionID, direction: "IMPORT",
                                       phase: value.phase, completed: value.progress.completed,
                                       total: value.progress.total, sessionID: value.sessionID,
                                       elapsedSeconds: value.elapsedSeconds)
        if let data = try? JSONEncoder().encode(display) {
            try? data.write(to: root.appendingPathComponent("direct-import-progress.json"), options: .atomic)
        }
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        // Foundation atomic replacement keeps the previous JSON readable until
        // the new complete value is ready. Never remove the visible file first.
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func pollOnce() async {
        let controlRoot = root; let known = acknowledged
        if let scan = try? await Task.detached(priority: .utility, operation: { try autoreleasepool { try ControlInbox.pending(in: controlRoot, ignoring: known) } }).value {
            acknowledged.formUnion(scan.responded)
            for item in scan.requests {
                guard let request = try? JSONSerialization.jsonObject(with: item.data) as? [String: Any], request["id"] as? String == item.id else { continue }
                let response = root.appendingPathComponent("Responses/\(item.id).json")
                do { try await handle(request, id: item.id, response: response) }
                catch { try? write(["status": "FAILED", "error": error.localizedDescription], to: response) }
                if FileManager.default.fileExists(atPath: response.path) { acknowledged.insert(item.id) }
            }
        }
        publishJob()
    }

    nonisolated private static func recoverJobs(in root: URL) {
        let jobs = root.appendingPathComponent("Jobs")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? [] where name.hasSuffix(".json") {
            let url = jobs.appendingPathComponent(name)
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), a[.type] as? FileAttributeType == .typeRegular,
                  let size = a[.size] as? NSNumber, size.intValue <= 65_536,
                  let data = try? Data(contentsOf: url), var job = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["SCANNING", "STAGING", "FINALIZING"].contains(job["status"] as? String ?? "") else { continue }
            job["status"] = "INTERRUPTED"; job["error"] = "iPhone App 已重新打开，请在 Mac 继续未完成的导出"
            try? JSONSerialization.data(withJSONObject: job, options: [.sortedKeys]).write(to: url, options: .atomic)
        }
    }

    func setForeground(_ foreground: Bool) {
        if phoneInForeground != foreground { connection.invalidate(); connected = false }
        phoneInForeground = foreground
        updateIdleTimer()
        publishJob()
    }

    func takeAutomaticImportRequest() -> AutomaticImportRequest? {
        defer { automaticImportRequest = nil }
        return automaticImportRequest
    }

    func finishAutomaticImport() {
        restoreInProgress = false
    }

    private func updateIdleTimer() {
        PhoneActivity.shared.set("export", active: active)
        PhoneActivity.shared.setForeground(phoneInForeground)
    }

    private func publishJob() {
        guard let id = activeRequestID else { return }
        if message != exporter.message { message = exporter.message }
        let rawDone = exporter.scanning ? exporter.scannedAssets : exporter.assetsCompleted
        let rawCount = exporter.scanning ? exporter.scanTotalAssets : exporter.totalAssets
        _ = macDisplayState.update(PhotoProgress(completed: rawDone, total: rawCount), operationID: id, phase: exporter.scanning ? "SCANNING" : exporter.state)
        let done = macDisplayState.progress.completed
        let count = macDisplayState.progress.total
        if completed != done { completed = done }; if total != count { total = count }
        let value: [String: Any] = ["requestID": id, "albumIdentifier": albumIdentifier,
            "status": exporter.state, "sessionID": exporter.sessionName ?? "",
            "phoneInForeground": phoneInForeground,
            "resourcesCompleted": exporter.resourcesCompleted, "totalResources": exporter.totalResources,
            "assetsCompleted": exporter.assetsCompleted, "totalAssets": exporter.totalAssets,
            "scannedAssets": exporter.scannedAssets, "scanTotalAssets": exporter.scanTotalAssets,
            "bytesCompleted": exporter.bytesCompleted, "message": exporter.message,
            "error": ["FAILED", "STOPPED"].contains(exporter.state) ? exporter.message : ""]
        do {
            let raw = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            if raw != lastJob { try raw.write(to: root.appendingPathComponent("Jobs/\(id).json"), options: .atomic); lastJob = raw }
        }
        catch { exporter.requestStop(); message = "连接记录无法保存，已暂停以保留照片" }
    }

    private func handle(_ request: [String: Any], id: String, response: URL) async throws {
        guard let expiry = request["expiresAt"] as? Double, expiry >= Date().timeIntervalSince1970,
              expiry <= Date().timeIntervalSince1970 + 600 else {
            throw NSError(domain: "PhotoBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "这次请求已过期，请在 Mac 重新操作"])
        }
        switch request["kind"] as? String {
        case "listAlbums":
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw NSError(domain: "PhotoBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "请在 iPhone 允许访问全部照片"])
            }
            try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    var albums: [[String: Any]] = []
                    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { collection, _, _ in
                        autoreleasepool { albums.append(["id": collection.localIdentifier, "name": collection.localizedTitle ?? "未命名相册",
                            "count": PHAsset.fetchAssets(in: collection, options: nil).count]) }
                    }
                    try PhotoOperationChecks.requireFullAccess()
                    try JSONSerialization.data(withJSONObject: ["status": "OK", "albums": albums], options: [.sortedKeys]).write(to: response, options: .atomic)
                }
            }.value
        case "startExport":
            guard !active && !exporter.busy && !restoreInProgress, let identifier = request["albumIdentifier"] as? String,
                  let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                throw NSError(domain: "PhotoBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "正在处理照片或相册已不可访问"])
            }
            // Durable acknowledgement precedes PhotoKit work, so relaunch never
            // silently repeats a previously accepted export.
            try write(["status": "ACCEPTED", "requestID": id], to: response)
            active = true; activeRequestID = id; albumIdentifier = identifier
            macDisplayState = ProgressDisplayState()
            exporter.sessionName = nil; exporter.state = "SCANNING"; exporter.message = "正在读取相册…"
            exporter.resourcesCompleted = 0; exporter.totalResources = 0
            exporter.scannedAssets = 0; exporter.scanTotalAssets = 0
            let allowNetwork = request["allowNetwork"] as? Bool ?? false
            let fast = request["fast"] as? Bool ?? false
            Task {
                await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: request["resumeSession"] as? String, fast: fast)
                active = false
                publishJob()
            }
        case "stopExport":
            if request["targetRequestID"] as? String == activeRequestID { exporter.requestStop() }
            try write(["status": "OK"], to: response)
        case "startImport":
            guard let sessionID = request["sessionID"] as? String,
                  UUID(uuidString: sessionID) != nil,
                  let title = request["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= 128 else {
                throw NSError(domain: "PhotoBridge", code: 5, userInfo: [NSLocalizedDescriptionKey: "收到的相册信息无效"])
            }
            guard !active && !exporter.busy && !restoreInProgress else {
                throw NSError(domain: "PhotoBridge", code: 6, userInfo: [NSLocalizedDescriptionKey: "iPhone 正在处理其他任务"])
            }
            try write(["status": "ACCEPTED", "sessionID": sessionID], to: response)
            restoreInProgress = true
            automaticImportRequest = AutomaticImportRequest(sessionID: sessionID, title: String(title.prefix(128)))
        case "directImportItem":
            guard !active && !exporter.busy,
                  let sessionID = request["sessionID"] as? String,
                  UUID(uuidString: sessionID) != nil,
                  let ordinal = request["ordinal"] as? Int,
                  let title = request["title"] as? String,
                  let relativePath = request["relativePath"] as? String,
                  let filename = request["filename"] as? String,
                  let uti = request["uniformTypeIdentifier"] as? String,
                  let resourceType = request["resourceType"] as? Int else {
                throw NSError(domain: "PhotoBridge", code: 7, userInfo: [NSLocalizedDescriptionKey: "导入项目无效或手机正在处理其他任务"])
            }
            try await directImporter.importItem(session: sessionID, ordinal: ordinal, title: String(title.prefix(128)),
                                                relativePath: relativePath, filename: filename,
                                                uniformTypeIdentifier: uti, resourceType: resourceType)
            try write(["status": "IMPORTED", "sessionID": sessionID, "ordinal": ordinal], to: response)
        case "directStartSession":
            guard let sessionID = request["sessionID"] as? String,
                  UUID(uuidString: sessionID) != nil,
                  let title = request["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let total = request["total"] as? Int,
                  total > 0, total <= 100_000 else {
                throw NSError(domain: "PhotoBridge", code: 8, userInfo: [NSLocalizedDescriptionKey: "导入任务信息无效"])
            }
            // A new direct session deliberately supersedes an old restore
            // journal. The live counter below is the only progress shown.
            restoreInProgress = false
            automaticImportRequest = nil
            macProgress = nil
            publishDirectProgress(DirectImportProgress(sessionID: sessionID, completed: 0, total: total, phase: "IMPORTING"))
            directImporter.startSession(session: sessionID, title: String(title.prefix(128)), total: total)
            try write(["status": "ACCEPTED", "sessionID": sessionID, "total": total], to: response)
        default:
            throw NSError(domain: "PhotoBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "请更新两端 PhotoBridge 后重试"])
        }
    }
}


struct MacExportCompanionView: View {
    @EnvironmentObject private var control: MacControlService
    @EnvironmentObject private var library: LibraryProbe
    @State private var showHelp = false
    var body: some View {
        ZStack {
            BridgeBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("导出到 Mac").font(.largeTitle.bold()).foregroundStyle(Color.bridgeInk)
                        Text("在电脑上选择相册，照片会按原顺序保存。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    PhoneConnectionStatus(connected: control.connected)
                    if library.loadingAlbums {
                        BridgeCard {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("正在读取相册…").font(.subheadline.weight(.semibold))
                            }
                        }
                    } else if library.authorization == .authorized && !library.albums.isEmpty {
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Text("选择相册").font(.headline)
                                    Spacer()
                                    Button("重新读取") { library.reload() }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.bridgeBlue)
                                }
                                ForEach(library.albums.prefix(8)) { item in
                                    NavigationLink { OriginalExportView(collection: item.collection) } label: {
                                        AlbumRow(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    } else {
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(library.authorization == .authorized ? "没有找到可显示的相册" : (library.authorization == .notDetermined ? "允许访问照片" : "需要全部照片权限"))
                                    .font(.headline)
                                Text(library.authorization == .authorized ? "可以点“重新读取”再次扫描相册。" : "允许后会显示你的相册，并出现“开始备份到 Mac”按钮。")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if library.authorization == .authorized {
                                    Button("重新读取") { library.reload() }
                                        .buttonStyle(BridgeButtonStyle(primary: true, tint: .bridgeExport, fill: .bridgeExportFill))
                                } else {
                                    Button(library.requestingPermission ? "正在请求…" : (library.authorization == .notDetermined ? "允许访问照片" : "打开照片设置")) {
                                    if library.authorization == .notDetermined {
                                        Task { await library.requestAccessOnly() }
                                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                    }
                                    .buttonStyle(BridgeButtonStyle(primary: true, tint: .bridgeExport, fill: .bridgeExportFill))
                                    .disabled(library.requestingPermission)
                                }
                            }
                        }
                    }
                    if let display = control.exportDisplay, display.direction == "TO_MAC" {
                        BridgeCard { PhotoCountView(title: display.presentationLabel(), progress: display.progress, elapsedSeconds: display.elapsedSeconds) }
                    } else if control.active {
                        BridgeCard { PhotoCountView(title: "正在准备照片", progress: control.preparationProgress) }
                    } else {
                        BridgeCard {
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: "laptopcomputer").font(.system(size: 32, weight: .light)).foregroundStyle(Color.bridgeBlue)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("在 Mac 上开始").font(.title3.weight(.semibold))
                                    Text("连接数据线，打开两端 PhotoBridge。在 Mac 选择相册和保存文件夹。")
                                        .font(.body).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("传输时请保持 App 在前台。原照片不会删除。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    AppVersionLabel()
                    DisclosureGroup("连接帮助", isExpanded: $showHelp) {
                        Text("打开两端 PhotoBridge，用数据线连接并解锁 iPhone。如出现提示，请选择“信任此电脑”。连接状态会自动更新。")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline).tint(.bridgeBlue)
                }.padding(24).frame(maxWidth: 580, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .task { library.reload() }
    }
}


struct PhotoCountView: View {
    let title: String
    let progress: PhotoProgress
    var elapsedSeconds: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if progress.total > 0 {
                HStack(alignment: .firstTextBaseline) {
                    if #available(iOS 17.0, *) {
                        Text(progress.countText).font(.title3.weight(.semibold)).frame(width: 150, alignment: .leading)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.18), value: progress.completed)
                    } else {
                        Text(progress.countText).font(.title3.weight(.semibold)).frame(width: 150, alignment: .leading)
                            .animation(.easeOut(duration: 0.18), value: progress.completed)
                    }
                    Spacer()
                    if #available(iOS 17.0, *) {
                        Text(progress.percentText).font(.title2.bold()).foregroundStyle(Color.bridgeBlue)
                            .frame(width: 56, alignment: .trailing)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.18), value: progress.percent)
                    } else {
                        Text(progress.percentText).font(.title2.bold()).foregroundStyle(Color.bridgeBlue)
                            .frame(width: 56, alignment: .trailing)
                            .animation(.easeOut(duration: 0.18), value: progress.percent)
                    }
                }.monospacedDigit()
                ProgressView(value: progress.fraction)
                    .tint(.bridgeBlue)
                    .animation(.linear(duration: 0.32), value: progress.fraction)
                if let elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0 {
                    Text("已用 \(elapsedText(elapsedSeconds))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if progress.finished {
                    CompletionBadge(title: "已完成", subtitle: "任务已完成")
                }
            } else {
                ProgressView("正在读取总张数…")
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func elapsedText(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return seconds < 60 ? "\(seconds) 秒" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }
}
