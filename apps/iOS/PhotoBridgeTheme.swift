import SwiftUI
import UIKit

extension Color {
    static let bridgeBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.86, blue: 0.70, alpha: 1) : UIColor(red: 0.11, green: 0.34, blue: 0.24, alpha: 1) })
    static let bridgeExport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.58, green: 0.84, blue: 0.68, alpha: 1) : UIColor(red: 0.10, green: 0.36, blue: 0.25, alpha: 1) })
    static let bridgeExportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.25, blue: 0.18, alpha: 1) : UIColor(red: 0.88, green: 0.95, blue: 0.90, alpha: 1) })
    static let bridgeImport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.74, green: 0.88, blue: 0.62, alpha: 1) : UIColor(red: 0.31, green: 0.45, blue: 0.21, alpha: 1) })
    static let bridgeImportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.22, green: 0.31, blue: 0.14, alpha: 1) : UIColor(red: 0.92, green: 0.95, blue: 0.84, alpha: 1) })
    static let bridgeSky = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.10, blue: 0.09, alpha: 1) : UIColor(red: 0.96, green: 0.98, blue: 0.97, alpha: 1) })
    static let connectedFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.29, blue: 0.19, alpha: 1) : UIColor(red: 0.79, green: 0.94, blue: 0.83, alpha: 1) })
    static let connectedInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.69, green: 0.94, blue: 0.76, alpha: 1) : UIColor(red: 0.10, green: 0.35, blue: 0.19, alpha: 1) })
    static let bridgeInk = Color(uiColor: .label)
    static let bridgeMuted = Color(uiColor: .secondaryLabel)
    static let bridgeButtonFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.13, green: 0.28, blue: 0.20, alpha: 1) : UIColor(red: 0.88, green: 0.95, blue: 0.91, alpha: 1) })
}

struct BridgeBackground: View {
    var body: some View { Color.bridgeSky.ignoresSafeArea() }
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
            .scaleEffect(connected ? 1 : 0.99)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: connected)
            .accessibilityIdentifier("connectionStatus")
    }
}

struct BridgeCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(22)
            .background(Color(uiColor: .systemBackground).opacity(0.94), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.bridgeBlue.opacity(0.06), radius: 16, y: 7)
    }
}

struct BridgeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    var tint: Color = .bridgeBlue
    var fill: Color?
    func makeBody(configuration: Configuration) -> some View {
        let foreground = primary ? (enabled ? Color.white : tint.opacity(0.55)) : Color.bridgeInk
        let background = primary ? (enabled ? tint : (fill ?? Color.bridgeButtonFill)) : Color(uiColor: .secondarySystemGroupedBackground)
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(minHeight: 46)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(enabled && !configuration.isPressed ? 0.055 : 0.015), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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
        .animation(.easeOut(duration: 0.18), value: connected)
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
