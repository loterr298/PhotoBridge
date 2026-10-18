import SwiftUI
import ImageCaptureCore

final class CameraDiscovery: NSObject, ObservableObject, ICDeviceBrowserDelegate {
    @Published var devices: [ICDevice] = []
    private let browser = ICDeviceBrowser()
    override init() { super.init(); browser.delegate = self }
    func start() { browser.start() }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) { devices.append(device) }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        devices.removeAll { $0 === device }
    }
}

@main struct PhotoBridgeMacApp: App {
    @StateObject private var discovery = CameraDiscovery()
    var body: some Scene {
        WindowGroup("PhotoBridge · 连接诊断") {
            NavigationSplitView {
                List { Section("相机目录 · ImageCaptureCore / PTP") {
                    ForEach(discovery.devices.indices, id: \.self) { i in
                        VStack(alignment: .leading) {
                            Text(discovery.devices[i].name ?? "未命名设备")
                            Text(discovery.devices[i].transportType ?? "未知链路").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if discovery.devices.isEmpty { Text("未发现相机设备").foregroundStyle(.secondary) }
                }}
            } detail: {
                VStack(alignment: .leading, spacing: 20) {
                    Text("照片传输").font(.largeTitle.bold())
                    Label("USB / AFC · 以实际校验报告为准", systemImage: "cable.connector")
                    Text("左侧是相机文件目录，不能用来判断 PhotoKit 相簿成员或手动顺序。")
                    Text("在终端运行随附 scripts/usb_probe.py。它仅选择 USB 设备，通过已配对的 House Arrest 访问 PhotoBridge Documents；没有连接时会报告 BLOCKED。")
                    Text("原始资源：iPhone 在相簿内完成暂存后，运行 scripts/album_export.py list，再 download 到全新本地目录。所有资源逐一核对大小和 SHA-256，结果写入 transfer-manifest.json。")
                    Text("iPhone 相簿顺序由诊断 App 导出，并与系统照片 App 逐项核对。")
                    Text("M1 导出验证版 · 照片库导回与相簿恢复尚未实现").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minWidth: 760, minHeight: 480).onAppear { discovery.start() }
        }
    }
}
