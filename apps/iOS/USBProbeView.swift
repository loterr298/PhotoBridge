import SwiftUI
import PhotoBridgeCore

struct USBProbeView: View {
    @State private var status = "还没有进行连接检查"
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("连接帮助") {
                    Text("这里可以检查数据线和 Mac 是否能正常传输文件，不会读取或修改照片。")
                    Text("测试文件约占 100 MB。完成后可在“文件”App 中删除测试文件。")
                    Button("生成连接测试文件") { generate() }.disabled(busy)
                    Button("检查 Mac 发来的文件") { validate() }.disabled(busy)
                    if busy { ProgressView() }
                    Text(status).textSelection(.enabled)
                }
                Section("怎么使用") {
                    Text("用数据线连接 iPhone，解锁后点“信任”。如果连接不稳定，暂时关闭 Wi-Fi 和个人热点，再重新检查。")
                    Text("这项检查只确认文件传输正常，不代表照片备份已经完成。")
                }
            }.navigationTitle("连接帮助")
        }
    }
    private func generate() {
        busy = true; status = "正在生成合成文件…"
        Task {
            do {
                let message = try await Task.detached(priority: .utility) {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let dir = docs.appendingPathComponent("USBProbe/Outbox/\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let receipt = try ProbeFiles.generate(at: dir.appendingPathComponent("probe.bin"), origin: "iPhone")
                    try JSONEncoder().encode(receipt).write(to: dir.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
                    return "测试文件已准备好：\(dir.lastPathComponent)\n约 100 MB，等待 Mac 检查"
                }.value
                status = message
            } catch { status = "没有完成：\(error.localizedDescription)" }
            busy = false
        }
    }
    private func validate() {
        busy = true
        Task {
            do {
                status = try await Task.detached(priority: .utility) {
                    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let inbox = docs.appendingPathComponent("USBProbe/Inbox")
                    let dirs = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
                    var reports: [String] = []
                    for dir in dirs {
                        do {
                            let expected = try JSONDecoder().decode(ProbeReceipt.self, from: Data(contentsOf: dir.appendingPathComponent("receipt.json")))
                            guard expected.filename == "probe.bin", expected.origin == "Mac", expected.byteCount >= 100 * 1024 * 1024 else {
                                throw DiagnosticError.invalidSize
                            }
                            let actual = try ProbeFiles.inspect(dir.appendingPathComponent("probe.bin"))
                            let match = actual.sha256 == expected.sha256 && actual.byteCount == expected.byteCount
                            let text = "\(dir.lastPathComponent)：\(match ? "检查通过" : "检查失败")"
                            let record = ["result": match ? "HASH_PASS" : "HASH_FAIL", "sha256": actual.sha256,
                                          "byteCount": String(actual.byteCount), "usbPhysicalTest": "requires Wi-Fi-off external evidence"]
                            let output = dir.appendingPathComponent("iphone-readback-\(UUID().uuidString).json")
                            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]).write(to: output, options: .withoutOverwriting)
                            reports.append(text)
                        } catch { reports.append("\(dir.lastPathComponent): FAIL · \(error.localizedDescription)") }
                    }
                    return reports.isEmpty ? "没有 Mac 收件测试文件" : reports.joined(separator: "\n\n")
                }.value
            } catch { status = "没有完成：\(error.localizedDescription)" }
            busy = false
        }
    }
}
