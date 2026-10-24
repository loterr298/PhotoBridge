import Foundation
import Photos
import SwiftUI
import UIKit

/// Request-scoped USB control. Only an open, authorized phone app reads Photos.
/// Accepted requests are recorded before work and never replayed after relaunch.
@MainActor
final class MacControlService: ObservableObject {
    let exporter = OriginalExportService()
    @Published var active = false
    @Published var message = "在 Mac 上选择相册和保存位置即可开始"
    @Published var completed = 0
    @Published var total = 0
    private var loop: Task<Void, Never>?
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
        let jobs = root.appendingPathComponent("Jobs")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: jobs.path)) ?? [] where name.hasSuffix(".json") {
            let url = jobs.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               var job = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               ["SCANNING", "STAGING", "FINALIZING"].contains(job["status"] as? String ?? "") {
                job["status"] = "INTERRUPTED"
                job["error"] = "iPhone App 已重新打开，请在 Mac 继续未完成的导出"
                try? write(job, to: url)
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollOnce()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        // Foundation atomic replacement keeps the previous JSON readable until
        // the new complete value is ready. Never remove the visible file first.
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    private func pollOnce() {
        let requests = root.appendingPathComponent("Requests")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) {
            for name in names where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                guard UUID(uuidString: id) != nil else { continue }
                let response = root.appendingPathComponent("Responses/\(id).json")
                guard !FileManager.default.fileExists(atPath: response.path),
                      let data = try? Data(contentsOf: requests.appendingPathComponent(name)), data.count <= 65_536,
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      request["id"] as? String == id else { continue }
                do { try handle(request, id: id, response: response) }
                catch { try? write(["status": "FAILED", "error": error.localizedDescription], to: response) }
            }
        }
        guard let id = activeRequestID else { return }
        message = exporter.message
        completed = exporter.scanning ? exporter.scannedAssets : exporter.resourcesCompleted
        total = exporter.scanning ? exporter.scanTotalAssets : exporter.totalResources
        let value: [String: Any] = ["requestID": id, "albumIdentifier": albumIdentifier,
            "status": exporter.state, "sessionID": exporter.sessionName ?? "",
            "resourcesCompleted": exporter.resourcesCompleted, "totalResources": exporter.totalResources,
            "scannedAssets": exporter.scannedAssets, "scanTotalAssets": exporter.scanTotalAssets,
            "bytesCompleted": exporter.bytesCompleted, "message": exporter.message,
            "error": ["FAILED", "STOPPED"].contains(exporter.state) ? exporter.message : ""]
        do { try write(value, to: root.appendingPathComponent("Jobs/\(id).json")) }
        catch { exporter.requestStop(); message = "连接记录无法保存，已暂停以保留照片" }
    }

    private func handle(_ request: [String: Any], id: String, response: URL) throws {
        guard let expiry = request["expiresAt"] as? Double, expiry >= Date().timeIntervalSince1970,
              expiry <= Date().timeIntervalSince1970 + 600 else {
            throw NSError(domain: "PhotoBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "这次请求已过期，请在 Mac 重新操作"])
        }
        switch request["kind"] as? String {
        case "listAlbums":
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                throw NSError(domain: "PhotoBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "请在 iPhone 允许访问全部照片"])
            }
            var albums: [[String: Any]] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { collection, _, _ in
                albums.append(["id": collection.localIdentifier, "name": collection.localizedTitle ?? "未命名相册",
                               "count": PHAsset.fetchAssets(in: collection, options: nil).count])
            }
            try write(["status": "OK", "albums": albums], to: response)
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
                pollOnce()
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
    var body: some View {
        ZStack {
            BridgeBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("导出到 Mac").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                    BridgeCard {
                        VStack(spacing: 20) {
                            BridgeIconCircle(systemImage: "laptopcomputer", tint: .bridgeBlue, size: 72)
                            Text(control.active ? "正在向 Mac 提供照片" : "在 Mac 上开始导出").font(.title2.bold())
                            Text("连接数据线，打开 Mac 上的 PhotoBridge，选择相册和保存文件夹。")
                                .foregroundStyle(Color.bridgeMuted).multilineTextAlignment(.center)
                            Text("导出期间请保持此 App 打开。")
                                .font(.subheadline).foregroundStyle(Color.bridgeMuted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    if library.authorization != .authorized {
                        BridgePrimaryButton(action: { Task { await library.request() } }) { Text("允许访问照片") }
                    }
                    if control.active {
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(control.message).font(.headline)
                                if control.total > 0 {
                                    ProgressView(value: Double(control.completed), total: Double(control.total)).tint(.bridgeBlue)
                                    Text("已读取 \(control.completed.formatted()) / \(control.total.formatted())")
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(Color.bridgeMuted)
                                } else { ProgressView("正在读取相册…") }
                                Text("保存进度和完成结果请查看 Mac。")
                                    .font(.caption).foregroundStyle(Color.bridgeMuted)
                            }
                        }
                    }
                    Text("保留相册顺序和原始画质，原照片不会删除。")
                        .font(.subheadline).foregroundStyle(Color.bridgeMuted)
                }.padding(24)
            }
        }
        .task { library.reload() }
        .onChange(of: control.active) { UIApplication.shared.isIdleTimerDisabled = $0 }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
