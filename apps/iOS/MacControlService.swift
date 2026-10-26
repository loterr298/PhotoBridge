import Foundation
import Photos
import SwiftUI
import PhotoBridgeCore

/// Request-scoped USB control. Only an open, authorized phone app reads Photos.
/// Accepted requests are recorded before work and never replayed after relaunch.
@MainActor
final class MacControlService: ObservableObject {
    let exporter = OriginalExportService()
    @Published var active = false { didSet { updateIdleTimer() } }
    @Published var message = "在 Mac 上选择相册和保存位置即可开始"
    @Published var completed = 0
    @Published var total = 0
    @Published var macProgress: TransferDisplay?
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
    private var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Control", isDirectory: true)
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
                if let url = self?.root.appendingPathComponent("transfer-progress.json") {
                    let value = await Task.detached(priority: .utility) { TransferDisplay.read(at: url) }.value
                    guard !Task.isCancelled else { return }
                    if let value, self?.macProgress != value { self?.macProgress = value }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
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

    private func updateIdleTimer() {
        PhoneActivity.shared.set("export", active: active)
        PhoneActivity.shared.setForeground(phoneInForeground)
    }

    private func publishJob() {
        guard let id = activeRequestID else { return }
        if message != exporter.message { message = exporter.message }
        let done = exporter.scanning ? exporter.scannedAssets : exporter.assetsCompleted
        let count = exporter.scanning ? exporter.scanTotalAssets : exporter.totalAssets
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
            guard !active && !exporter.busy, let identifier = request["albumIdentifier"] as? String,
                  let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                throw NSError(domain: "PhotoBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "正在处理照片或相册已不可访问"])
            }
            // Durable acknowledgement precedes PhotoKit work, so relaunch never
            // silently repeats a previously accepted export.
            try write(["status": "ACCEPTED", "requestID": id], to: response)
            active = true; activeRequestID = id; albumIdentifier = identifier
            exporter.sessionName = nil; exporter.state = "SCANNING"; exporter.message = "正在读取相册…"
            exporter.resourcesCompleted = 0; exporter.totalResources = 0
            exporter.scannedAssets = 0; exporter.scanTotalAssets = 0
            let allowNetwork = request["allowNetwork"] as? Bool ?? false
            Task {
                await exporter.start(collection: collection, allowNetwork: allowNetwork, resumeSession: request["resumeSession"] as? String)
                active = false
                publishJob()
            }
        case "stopExport":
            if request["targetRequestID"] as? String == activeRequestID { exporter.requestStop() }
            try write(["status": "OK"], to: response)
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
                    if let display = control.exportDisplay, display.direction == "TO_MAC" {
                        BridgeCard { PhotoCountView(title: display.presentationLabel(), progress: display.progress) }
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
                    if library.authorization != .authorized {
                        BridgePrimaryButton(action: { Task { await library.requestAccessOnly() } }) { Text("允许访问照片") }
                    }
                    Text("传输时请保持 App 在前台。原照片不会删除。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    DisclosureGroup("连接帮助", isExpanded: $showHelp) {
                        Text("打开两端 PhotoBridge，用数据线连接并解锁 iPhone。如出现提示，请选择“信任此电脑”。连接状态会自动更新。")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.subheadline).tint(.bridgeBlue)
                }.padding(24).frame(maxWidth: 580, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .task { library.reloadAuthorization() }
    }
}


struct PhotoCountView: View {
    let title: String
    let progress: PhotoProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if progress.total > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(progress.countText).font(.title3.weight(.semibold))
                    Spacer()
                    Text(progress.percentText).font(.title2.bold()).foregroundStyle(Color.bridgeBlue)
                }.monospacedDigit()
                ProgressView(value: progress.fraction).tint(.bridgeBlue)
            } else {
                ProgressView("正在读取总张数…")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
