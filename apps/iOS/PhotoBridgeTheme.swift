import SwiftUI
import UIKit

extension Color {
    static let bridgeBlue = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.62, green: 0.86, blue: 0.70, alpha: 1) : UIColor(red: 0.11, green: 0.34, blue: 0.24, alpha: 1) })
    static let bridgeExport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.58, green: 0.84, blue: 0.68, alpha: 1) : UIColor(red: 0.10, green: 0.36, blue: 0.25, alpha: 1) })
    static let bridgeExportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.25, blue: 0.18, alpha: 1) : UIColor(red: 0.88, green: 0.95, blue: 0.90, alpha: 1) })
    static let bridgeImport = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.74, green: 0.88, blue: 0.62, alpha: 1) : UIColor(red: 0.31, green: 0.45, blue: 0.21, alpha: 1) })
    static let bridgeImportFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.22, green: 0.31, blue: 0.14, alpha: 1) : UIColor(red: 0.92, green: 0.95, blue: 0.84, alpha: 1) })
    static let bridgeSky = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.10, blue: 0.09, alpha: 1) : UIColor.white })
    static let connectedFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.29, blue: 0.19, alpha: 1) : UIColor(red: 0.79, green: 0.94, blue: 0.83, alpha: 1) })
    static let connectedInk = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.69, green: 0.94, blue: 0.76, alpha: 1) : UIColor(red: 0.10, green: 0.35, blue: 0.19, alpha: 1) })
    static let bridgeInk = Color(uiColor: .label)
    static let bridgeMuted = Color(uiColor: .secondaryLabel)
    static let bridgeButtonFill = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.13, green: 0.28, blue: 0.20, alpha: 1) : UIColor(red: 0.88, green: 0.95, blue: 0.91, alpha: 1) })
}

struct BridgeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.910, green: 0.965, blue: 0.945),
                    Color(red: 0.955, green: 0.965, blue: 0.995),
                    Color(red: 0.900, green: 0.955, blue: 0.945)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 0.54, green: 0.84, blue: 0.68).opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 440
            )
            RadialGradient(
                colors: [Color(red: 0.60, green: 0.75, blue: 0.98).opacity(0.16), .clear],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

struct AppVersionLabel: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "7"
        Text("v\(version) (\(build))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(Color.bridgeMuted)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("版本 \(version)，构建 \(build)")
    }
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
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        content.padding(22)
            .background(.ultraThinMaterial, in: shape)
            .background(Color.white.opacity(0.76), in: shape)
            .overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.26), Color.white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)
                .allowsHitTesting(false)
            )
            .overlay(shape.stroke(Color.white.opacity(0.72), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: Color.black.opacity(0.055), radius: 14, y: 6)
    }
}

struct BridgeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var primary = false
    var tint: Color = .bridgeBlue
    var fill: Color?
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let foreground = primary ? (enabled ? tint : tint.opacity(0.42)) : Color.bridgeInk
        let tintOpacity = enabled ? (configuration.isPressed ? 0.22 : 0.14) : 0.06
        configuration.label.font(.body.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(minHeight: 46)
            .foregroundStyle(foreground)
            .background(.regularMaterial, in: shape)
            .background(primary ? tint.opacity(tintOpacity) : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.68), in: shape)
            .overlay(shape.stroke(primary ? tint.opacity(enabled ? 0.30 : 0.12) : Color.white.opacity(0.78), lineWidth: 1).allowsHitTesting(false))
            .shadow(color: tint.opacity(enabled && !configuration.isPressed ? 0.12 : 0.03), radius: 7, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.45)
            .contentShape(shape)
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

struct CompletionBadge: View {
    let title: String
    let subtitle: String
    var tint: Color = .connectedInk
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)
            .scaleEffect(visible ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { visible = true }
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
