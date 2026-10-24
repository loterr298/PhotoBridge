import Foundation
import Darwin
import PhotoBridgeCore

func peakRSS() -> Int64 { var value = rusage(); getrusage(RUSAGE_SELF, &value); return Int64(value.ru_maxrss) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let file = root.appendingPathComponent("synthetic.bin")
try autoreleasepool { try Data(repeating: 0, count: 16 * 1024 * 1024).write(to: file) }
let before = peakRSS()
try autoreleasepool {
    // One long-lived pool models the full staging readback task on Darwin.
    for _ in 0..<32 {
        let receipt = try ProbeFiles.inspect(file)
        guard receipt.byteCount == 16 * 1024 * 1024,
              receipt.sha256 == "080acf35a507ac9849cfcba47dc2ad83e01b75663a516279c8b9d243b719643e" else { fatalError("Hash/size changed") }
    }
}
let growth = peakRSS() - before
print("512 MiB synthetic readback: peak RSS growth \(growth) bytes")
guard growth < 64 * 1024 * 1024 else { fputs("FAIL: hash readback retains media-sized temporary buffers\n", stderr); exit(1) }
print("PASS: repeated hash readback keeps temporary memory bounded")
