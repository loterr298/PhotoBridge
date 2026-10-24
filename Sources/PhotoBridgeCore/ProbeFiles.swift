import Foundation
import CryptoKit

public struct ProbeReceipt: Codable, Equatable {
    public let filename: String
    public let sha256: String
    public let byteCount: Int
    public let origin: String
    public init(filename: String, sha256: String, byteCount: Int, origin: String) {
        self.filename = filename; self.sha256 = sha256; self.byteCount = byteCount; self.origin = origin
    }
}
public enum ProbeFiles {
    /// Bounded 1 MiB buffer, synthetic bytes only. Fails rather than replacing any file.
    public static func generate(at url: URL, byteCount: Int = 100 * 1024 * 1024, origin: String) throws -> ProbeReceipt {
        guard byteCount > 0 else { throw DiagnosticError.invalidSize }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var remaining = byteCount
        var hash = SHA256()
        while remaining > 0 {
            let count = min(remaining, 1024 * 1024)
            var bytes = [UInt8](repeating: 0, count: count)
            let code = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
            let chunk = Data(bytes); try handle.write(contentsOf: chunk); hash.update(data: chunk); remaining -= count
        }
        try handle.synchronize()
        return ProbeReceipt(filename: url.lastPathComponent,
                            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            byteCount: byteCount, origin: origin)
    }
    public static func inspect(_ url: URL) throws -> ProbeReceipt {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var count = 0
        while true {
            // Darwin FileHandle can retain autoreleased NSData until the outer
            // task pool drains. Keep each chunk and its hash update in one pool.
            let size = try autoreleasepool { () throws -> Int in
                guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
                hash.update(data: data)
                return data.count
            }
            if size == 0 { break }
            count += size
        }
        return ProbeReceipt(filename: url.lastPathComponent,
                            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            byteCount: count, origin: "readback")
    }
}
