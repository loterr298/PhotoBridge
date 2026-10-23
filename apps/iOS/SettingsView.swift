import SwiftUI

struct SettingsView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(short) (\(build))"
    }
    var body: some View {
        NavigationStack {
            ZStack {
                BridgeBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("设置").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.bridgeInk)
                        BridgeCard {
                            HStack(spacing: 14) {
                                BridgeIconCircle(systemImage: "photo.on.rectangle.angled", tint: .bridgeBlue, size: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("PhotoBridge").font(.title3.bold())
                                    Text("版本 \(version)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("照片保护").font(.headline)
                                SettingLine(icon: "lock.shield.fill", title: "保留原图", detail: "不删除、不覆盖、不压缩", tint: .green)
                                SettingLine(icon: "arrow.up.arrow.down", title: "保留相册顺序", detail: "恢复时按原来的位置排列", tint: .bridgeBlue)
                                SettingLine(icon: "checkmark.shield.fill", title: "自动检查", detail: "保存完成后确认文件完整", tint: .purple)
                            }
                        }
                        BridgeCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("连接帮助").font(.headline)
                                Text("请使用数据线连接 iPhone，在手机上点“信任此电脑”。").font(.subheadline).foregroundStyle(.secondary)
                                Text("照片只在你的 iPhone 和 Mac 之间传输。").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

private struct SettingLine: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
