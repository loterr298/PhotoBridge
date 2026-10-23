import SwiftUI

extension Color {
    static let bridgeBlue = Color(red: 0.16, green: 0.52, blue: 0.96)
    static let bridgeSky = Color(red: 0.89, green: 0.95, blue: 1.0)
    static let bridgeInk = Color(red: 0.08, green: 0.13, blue: 0.22)
    static let bridgeMuted = Color(red: 0.38, green: 0.47, blue: 0.62)
}

struct BridgeBackground: View {
    var body: some View {
        LinearGradient(colors: [.bridgeSky.opacity(0.72), Color(uiColor: .systemGroupedBackground), .white.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct BridgeCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1))
            .shadow(color: .blue.opacity(0.08), radius: 18, y: 8)
    }
}

struct BridgeIconCircle: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 54
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: Circle())
    }
}

struct BridgeStatus: View {
    let title: String
    let connected: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(connected ? .green : .gray.opacity(0.65)).frame(width: 9, height: 9)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct BridgePrimaryButton<Label: View>: View {
    let action: () -> Void
    let label: Label
    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) { self.action = action; self.label = label() }
    var body: some View {
        Button(action: action) { label.frame(maxWidth: .infinity).padding(.vertical, 13) }
            .buttonStyle(.borderedProminent)
            .tint(.bridgeBlue)
            .controlSize(.large)
    }
}
