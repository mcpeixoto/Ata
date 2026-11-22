import Foundation

/// How a locked control reaches the paywall. The Mac Pro window is owned by
/// another part of the app, which replaces `presentPaywall`; until it does, the
/// tap is still counted and nothing is presented.
/// Which feature opened the paywall, so that line can lead. Cleared when the
/// paywall is opened from anywhere else.
@MainActor
final class PaywallFocus: ObservableObject {
    static let shared = PaywallFocus()
    @Published var feature: ProFeature?
}

@MainActor
enum ProGate {
    static var presentPaywall: (ProFeature) -> Void = { _ in }

    static func allows(_ feature: ProFeature) -> Bool {
        ProAccess.shared.isPro
    }

    /// False when `feature` is locked: the tap is counted and the paywall opens.
    /// True when it is already unlocked, and nothing else happens.
    @discardableResult
    static func lockedTap(_ feature: ProFeature, isPro: Bool, defaults: UserDefaults = Pref.d) -> Bool {
        if isPro { return true }
        Funnel.count(.featureLocked(feature), defaults: defaults)
        presentPaywall(feature)
        return false
    }
}
