import Foundation
import SwiftUI

@MainActor
final class TransferCacheManager: ObservableObject {
    @Published private(set) var fileCount = 0
    @Published private(set) var byteCount: Int64 = 0
    @Published private(set) var message = ""

    private let fileManager = FileManager.default
    private var documents: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var managedDirectories: [URL] {
        ["DirectInbox", "RestoreInbox", "Exports"].map { documents.appendingPathComponent($0, isDirectory: true) }
    }

    func refresh() async {
        let roots = managedDirectories
        let result = await Task.detached(priority: .utility) {
            Self.measure(roots: roots)
        }.value
        fileCount = result.files
        byteCount = result.bytes
    }

    func clear() async {
        for root in managedDirectories {
            try? fileManager.removeItem(at: root)
        }
        let control = documents.appendingPathComponent("Control", isDirectory: true)
        for name in ["direct-import-progress.json", "transfer-progress.json", "restore-progress.json"] {
            try? fileManager.removeItem(at: control.appendingPathComponent(name))
        }
        message = "传输缓存已清理"
        await refresh()
    }

    private static func measure(roots: [URL]) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let manager = FileManager.default
        for root in roots {
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (files, bytes)
    }
}
