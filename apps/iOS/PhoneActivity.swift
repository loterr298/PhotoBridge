import UIKit
import PhotoBridgeCore

@MainActor
final class PhoneActivity {
    static let shared = PhoneActivity()
    private var state = WorkActivity()
    func set(_ key: String, active: Bool) {
        state.set(key, active: active)
        UIApplication.shared.isIdleTimerDisabled = state.preventsIdle
    }
    func setForeground(_ active: Bool) {
        state.foreground = active
        UIApplication.shared.isIdleTimerDisabled = state.preventsIdle
    }
}
