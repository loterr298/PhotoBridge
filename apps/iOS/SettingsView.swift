import SwiftUI

struct SettingsView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PhotoBridge").font(.title2.bold())
                        Text("安全保存和恢复照片")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("版本 \(version)")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("照片保护") {
                    PolicyRow(title: "保留原图", detail: "不删除、不覆盖、不压缩", icon: "lock.shield.fill", tint: .green)
                    PolicyRow(title: "逐张检查", detail: "保存前后确认文件完整", icon: "checkmark.shield.fill", tint: .blue)
                    PolicyRow(title: "保留拍摄信息", detail: "不改变照片里的拍摄信息", icon: "doc.text.magnifyingglass", tint: .purple)
                }

                Section("相册顺序") {
                    PolicyRow(title: "按原相册顺序保存", detail: "恢复后会创建新的相册并保留位置", icon: "arrow.up.arrow.down", tint: .secondary)
                    PolicyRow(title: "不改变拍摄时间", detail: "Mac 上的整理方式不会改照片日期", icon: "clock", tint: .orange)
                }

                Section("连接和权限") {
                    NavigationLink {
                        USBProbeView()
                    } label: {
                        Label("连接帮助", systemImage: "cable.connector.horizontal")
                    }
                    Text("为了显示和保存完整相册，请在系统设置中允许访问全部照片。连接状态以 Mac 上的实际结果为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("关于") {
                    Text("版本 \(version)。PhotoBridge 只在你的 iPhone 和 Mac 之间工作，不上传照片。首次安装需要使用 Apple ID 完成安装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }
}

private struct PolicyRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
