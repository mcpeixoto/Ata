import StoreKit
import UIKit

/// When to ask for an App Store review. After the third transcript that
/// succeeded, never while a recording is going, at most once for a version,
/// and not on a day the Pro sheet was already shown.
enum ReviewPrompt {
    static let afterTranscripts = 3

    static func shouldRequest(successfulTranscripts: Int, isRecording: Bool,
                              lastPromptedVersion: String?, currentVersion: String,
                              proSheetShownToday: Bool) -> Bool {
        guard successfulTranscripts >= afterTranscripts, !isRecording, !proSheetShownToday else { return false }
        guard !currentVersion.isEmpty, lastPromptedVersion != currentVersion else { return false }
        return true
    }

    /// The system sheet. It may still decide not to show anything.
    @MainActor
    static func requestReview() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        SKStoreReviewController.requestReview(in: scene)
    }
}
