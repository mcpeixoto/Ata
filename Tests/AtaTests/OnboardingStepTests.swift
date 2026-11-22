@testable import Ata
import XCTest

final class OnboardingStepTests: XCTestCase {
    private func shown(_ persisted: Int?, onboarded: Bool = false, mic: Bool = true,
                       missing: Bool = false, apple: AppleIntelligenceState = .ready) -> OnboardingStep {
        OnboardingStep.shown(persisted: persisted, onboarded: onboarded, mic: mic,
                             systemAudioMissing: missing, apple: apple)
    }

    func testAFirstRunStartsAtTheWelcome() {
        XCTAssertEqual(shown(nil, mic: false, missing: true), .welcome)
        XCTAssertEqual(shown(0, mic: false, missing: true), .welcome, "not past the welcome yet")
    }

    /// The Mac audio grant restarts Ata. It must come back to the permissions
    /// step, now with ticks, not jump ahead to what is no longer missing.
    func testTheRestartAfterTheAudioGrantLandsOnPermissions() {
        XCTAssertEqual(shown(OnboardingStep.permissions.rawValue), .permissions)
        XCTAssertEqual(shown(OnboardingStep.permissions.rawValue, apple: .off), .permissions)
    }

    func testTheShownStepIsTheFurtherOfStoredAndFirstUnmet() {
        XCTAssertEqual(OnboardingStep.firstUnmet(persisted: nil, mic: true, systemAudioMissing: false), .welcome)
        XCTAssertEqual(OnboardingStep.firstUnmet(persisted: 1, mic: false, systemAudioMissing: false), .permissions)
        XCTAssertEqual(OnboardingStep.firstUnmet(persisted: 1, mic: true, systemAudioMissing: true), .permissions)
        XCTAssertNil(OnboardingStep.firstUnmet(persisted: 1, mic: true, systemAudioMissing: false))
        XCTAssertEqual(shown(OnboardingStep.test.rawValue), .test, "a later step is kept")
        // Continued without Mac audio: Mac audio is still missing, but the step reached wins.
        XCTAssertEqual(shown(OnboardingStep.you.rawValue, missing: true), .you)
    }

    func testSummariesAreSkippedWhenAppleIntelligenceHasNothingToAsk() {
        XCTAssertFalse(OnboardingStep.sequence(apple: .ready).contains(.summaries))
        XCTAssertFalse(OnboardingStep.sequence(apple: .unsupported).contains(.summaries))
        XCTAssertTrue(OnboardingStep.sequence(apple: .off).contains(.summaries))
        XCTAssertTrue(OnboardingStep.sequence(apple: .preparing).contains(.summaries))
        XCTAssertEqual(OnboardingStep.permissions.next(apple: .ready), .you)
        XCTAssertEqual(OnboardingStep.permissions.next(apple: .off), .summaries)
        XCTAssertEqual(OnboardingStep.you.previous(apple: .ready), .permissions)
        XCTAssertEqual(OnboardingStep.you.previous(apple: .preparing), .summaries)
        // Stored on summaries, and Apple Intelligence was turned on meanwhile.
        XCTAssertEqual(shown(OnboardingStep.summaries.rawValue, apple: .ready), .you)
        XCTAssertEqual(shown(OnboardingStep.summaries.rawValue, apple: .off), .summaries)
    }

    func testTheEndsOfTheSequence() {
        XCTAssertNil(OnboardingStep.welcome.previous(apple: .ready))
        XCTAssertEqual(OnboardingStep.done.next(apple: .ready), .done)
        XCTAssertEqual(OnboardingStep.sequence(apple: .ready), [.welcome, .permissions, .you, .test, .done])
        XCTAssertEqual(shown(99), .done, "a step from a newer build lands on the last one")
    }

    /// "Finish setting up" reopens a finished setup at what is missing, and
    /// someone who finished never sees the welcome again.
    func testAReopenedSetupGoesToWhatIsMissing() {
        XCTAssertEqual(shown(nil, onboarded: true, mic: false), .permissions)
        XCTAssertEqual(shown(OnboardingStep.done.rawValue, onboarded: true, missing: true), .permissions)
        XCTAssertEqual(shown(nil, onboarded: true), .done)
        XCTAssertEqual(shown(OnboardingStep.you.rawValue, onboarded: true), .done)
    }

    func testStoredValuesNeverChange() {
        // Pref.onboardingStep and the funnel store these numbers.
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
    }
}
