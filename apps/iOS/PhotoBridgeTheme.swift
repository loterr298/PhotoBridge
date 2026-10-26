import SwiftUI
import UIKit

extension Color {
    static let bridgeBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.65, green: 0.76, blue: 0.82, alpha: 1) : UIColor(red: 0.28, green: 0.39, blue: 0.46, alpha: 1) })
    static let bridgeSky = Color(uiColor: .systemGroupedBackground)
    static let bridgeInk = Color(uiColor: .label)
    static let bridgeMuted = Color(uiColor: .secondaryLabel)
    static let bridgeButtonFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.21, green: 0.28, blue: 0.32, alpha: 1) : UIColor(red: 0.87, green: 0.91, blue: 0.93, alpha: 1) })
}

struct BridgeBackground: View {
    var body: some View { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(minHeight: 46)
            .foregroundStyle(primary ? Color.bridgeBlue : Color.bridgeInk)
            .background(primary ? Color.bridgeButtonFill : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
