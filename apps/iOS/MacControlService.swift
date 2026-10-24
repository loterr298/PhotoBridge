import Foundation
import Photos

/// Lets the Mac drive the export without asking the user to repeat the same
/// action on the phone. The phone only answers while PhotoBridge is open;
/// Photos permission and the USB trust prompt remain controlled by iOS.
@MainActor
final class MacControlService: ObservableObject {
    private let exporter = OriginalExportService()
    private var loop: Task<Void, Never>?
    private var handledRequests = Set<String>()

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var root: URL { documents.appendingPathComponent("Control", isDirectory: true) }
    private var requests: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    private var responses: URL { root.appendingPathComponent("Responses", isDirectory: true) }
    private var statusURL: URL { root.appendingPathComponent("status.json") }

    func start() {
        guard loop == nil else { return }
        try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    private func pollOnce() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) {
            for name in names where name.hasSuffix(".json") && !name.hasSuffix(".part") {
                let url = requests.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = request["id"] as? String,
                      !handledRequests.contains(id) else { continue }
                handledRequests.insert(id)
                try? FileManager.default.removeItem(at: url)
                handle(request, id: id)
            }
        }
        writeStatus()
    }

    private func handle(_ request: [String: Any], id: String) {
        guard let kind = request["kind"] as? String else {
            writeResponse(id: id, value: ["status": "FAILED", "error": "无法识别 Mac 请求"])
            return
        }
        switch kind {
        case "listAlbums":
            writeResponse(id: id, value: ["status": "OK", "albums": albumList()])
        case "startExport":
            guard !exporter.busy else {
                writeResponse(id: id, value: ["status": "FAILED", "error": "iPhone 正在准备另一份照片"])
                return
            }
            guard let identifier = request["albumIdentifier"] as? String,
                  let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                writeResponse(id: id, value: ["status": "FAILED", "error": "找不到所选相册"])
                return
            }
            let allowNetwork = request["allowNetwork"] as? Bool ?? false
            writeResponse(id: id, value: ["status": "ACCEPTED", "albumName": collection.localizedTitle ?? "我的相册"])
            Task { [weak self] in
                guard let self else { return }
                await self.exporter.start(collection: collection, allowNetwork: allowNetwork)
                self.writeStatus()
            }
        default:
            writeResponse(id: id, value: ["status": "FAILED", "error": "不支持的操作"])
        }
    }

    private func albumList() -> [[String: Any]] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var result: [[String: Any]] = []
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            result.append(["id": collection.localIdentifier,
                           "name": collection.localizedTitle ?? "未命名相册",
                           "count": assets.count])
        }
        return result
    }

    private func writeResponse(id: String, value: [String: Any]) {
        let url = responses.appendingPathComponent("\(id).json")
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let part = url.appendingPathExtension("part")
        try? data.write(to: part, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: part, to: url)
    }

    private func writeStatus() {
        let value: [String: Any] = [
            "status": exporter.busy ? (exporter.scanning ? "SCANNING" : "STAGING") : (exporter.sessionName == nil ? "IDLE" : (exporter.message.hasPrefix("保存完成") ? "STAGED" : "READY")),
            "sessionID": exporter.sessionName ?? "",
            "resourcesCompleted": exporter.resourcesCompleted,
            "totalResources": exporter.totalResources,
            "bytesCompleted": exporter.bytesCompleted,
            "message": exporter.message,
            "error": exporter.message.hasPrefix("没有完成") ? exporter.message : ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let part = statusURL.appendingPathExtension("part")
        try? data.write(to: part, options: .atomic)
        try? FileManager.default.removeItem(at: statusURL)
        try? FileManager.default.moveItem(at: part, to: statusURL)
    }
}
