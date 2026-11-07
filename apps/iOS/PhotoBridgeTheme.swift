import SwiftUI
import UIKit

extension Color {
    static let bridgeBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.86, blue: 0.68, alpha: 1) : UIColor(red: 0.18, green: 0.48, blue: 0.29, alpha: 1) })
    static let bridgeExport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.58, green: 0.76, blue: 0.92, alpha: 1) : UIColor(red: 0.20, green: 0.39, blue: 0.57, alpha: 1) })
    static let bridgeExportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.22, blue: 0.31, alpha: 1) : UIColor(red: 0.88, green: 0.94, blue: 0.98, alpha: 1) })
    static let bridgeImport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.86, blue: 0.68, alpha: 1) : UIColor(red: 0.14, green: 0.40, blue: 0.23, alpha: 1) })
    static let bridgeImportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.29, blue: 0.19, alpha: 1) : UIColor(red: 0.84, green: 0.95, blue: 0.87, alpha: 1) })
    static let bridgeSky = Color(uiColor: .systemGroupedBackground)
    static let connectedFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.29, blue: 0.19, alpha: 1) : UIColor(red: 0.79, green: 0.94, blue: 0.83, alpha: 1) })
    static let connectedInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.69, green: 0.94, blue: 0.76, alpha: 1) : UIColor(red: 0.10, green: 0.35, blue: 0.19, alpha: 1) })
    static let bridgeInk = Color(uiColor: .label)
    static let bridgeMuted = Color(uiColor: .secondaryLabel)
    static let bridgeButtonFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.16, green: 0.30, blue: 0.20, alpha: 1) : UIColor(red: 0.84, green: 0.95, blue: 0.87, alpha: 1) })
}

struct BridgeBackground: View {
    var body: some View { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
}

struct PhoneConnectionStatus: View {
    let connected: Bool
    var body: some View {
        Label(connected ? "Mac 已连接 · USB" : "等待 Mac 连接", systemImage: connected ? "checkmark.circle.fill" : "cable.connector")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(connected ? Color.connectedInk : Color.bridgeMuted)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(connected ? Color.connectedFill : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("connectionStatus")
    }
}

struct BridgeCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(22)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

struct BridgeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    var tint: Color = .bridgeBlue
    var fill: Color?
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(minHeight: 46)
            .foregroundStyle(primary ? tint : Color.bridgeInk)
            .background(primary ? (fill ?? Color.bridgeButtonFill) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(enabled && !configuration.isPressed ? 0.055 : 0.015), radius: 6, y: 3)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct BridgeIconCircle: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 54
    var body: some View {
        Image(systemName: systemImage).font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(0.08), in: Circle())
    }
}

struct BridgeStatus: View {
    let title: String
    let connected: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(connected ? Color(red: 0.36, green: 0.55, blue: 0.45) : .gray.opacity(0.6)).frame(width: 7, height: 7)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

struct BridgePrimaryButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) { self.action = action; self.label = label() }
    var body: some View {
        Button(action: action) { label.frame(maxWidth: .infinity) }.buttonStyle(BridgeButtonStyle(primary: true))
    }
}
