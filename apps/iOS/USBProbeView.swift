import SwiftUI
import PhotoBridgeCore

struct USBProbeView: View {
    @State private var status = "尚未执行双向 USB 校验"
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("USB / AFC 真机探针") {
                    Text("链路由 Mac 检测 · 本页不显示实时连接状态")
                    Text("生成的是随机测试数据，不读取照片。每次约占 100 MiB，测试文件保留，可在文件 App 手动清理。")
                    Button("生成 iPhone → Mac 100 MiB 文件") { generate() }.disabled(busy)
                    Button("校验 Mac → iPhone 收件文件") { validate() }.disabled(busy)
                    if busy { ProgressView() }
                    Text(status).textSelection(.enabled)
                }
                Section("真 USB 验证方法") {
                    Text("连接并信任 Mac，关闭两端 Wi-Fi 及 iPhone 个人热点。Mac 脚本只选择 USB 设备。先下载 Outbox 探针，再上传另一份到 Inbox，最后点校验。")
                    Text("沙盒文件 hash 通过仅验证数据通道；原图、PhotoKit 导回及相簿恢复仍待下一阶段。")
                }
            }.navigationTitle("传输诊断")
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
                    return "已生成：\(dir.lastPathComponent)\n100 MiB · SHA-256 \(receipt.sha256)\n仅本机生成，USB 待测"
                }.value
                status = message
            } catch { status = "失败：\(error.localizedDescription)" }
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
                            let text = "\(dir.lastPathComponent): \(match ? "HASH_PASS" : "HASH_FAIL") · \(actual.byteCount) bytes\n\(actual.sha256)"
                            let record = ["result": match ? "HASH_PASS" : "HASH_FAIL", "sha256": actual.sha256,
                                          "byteCount": String(actual.byteCount), "usbPhysicalTest": "requires Wi-Fi-off external evidence"]
                            let output = dir.appendingPathComponent("iphone-readback-\(UUID().uuidString).json")
                            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]).write(to: output, options: .withoutOverwriting)
                            reports.append(text)
                        } catch { reports.append("\(dir.lastPathComponent): FAIL · \(error.localizedDescription)") }
                    }
                    return reports.isEmpty ? "没有 Mac 收件测试文件" : reports.joined(separator: "\n\n")
                }.value
            } catch { status = "未完成：\(error.localizedDescription)" }
            busy = false
        }
    }
}
