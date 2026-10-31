@testable import Ata
import AppKit
import XCTest

/// The Mac's easy defaults: menu bar, Whisper Large, Apple Intelligence.
final class MenuBarHomeTests: XCTestCase {
    func testTheMenuBarHomeIsAppliedOnce() {
        let defaults = UserDefaults(suiteName: "ai.interactive.ata.tests.menubar")!
        defaults.removePersistentDomain(forName: "ai.interactive.ata.tests.menubar")

        defaults.set(true, forKey: Pref.dockIcon)
        defaults.set(false, forKey: Pref.menuBarIcon)
        defaults.set(Engine.openAI.rawValue, forKey: Pref.engine)
        defaults.set("turbo", forKey: Pref.localModel)
        defaults.set(false, forKey: Pref.summarize)
        defaults.set("auto", forKey: Pref.summaryEngine)

        Pref.applyMenuBarHome(to: defaults)

        XCTAssertFalse(defaults.bool(forKey: Pref.dockIcon))
        XCTAssertTrue(defaults.bool(forKey: Pref.menuBarIcon))
        XCTAssertEqual(defaults.string(forKey: Pref.engine), Engine.local.rawValue)
        XCTAssertEqual(defaults.string(forKey: Pref.localModel), LocalModel.defaultID)
        XCTAssertTrue(defaults.bool(forKey: Pref.summarize))
        XCTAssertEqual(defaults.string(forKey: Pref.summaryEngine), SummaryEngine.apple.rawValue)

        defaults.set(true, forKey: Pref.dockIcon)
        Pref.applyMenuBarHome(to: defaults)
        XCTAssertTrue(defaults.bool(forKey: Pref.dockIcon), "a later choice in Settings is left alone")
    }

    @MainActor
    func testAnIdleAppWithoutTheDockIsAnAccessory() {
        XCTAssertEqual(Presence.policyWhenIdle(dock: false), .accessory)
        XCTAssertEqual(Presence.policyWhenIdle(dock: true), .regular)
    }
}

/// OpenAI is no longer a way to transcribe or summarize.
final class OnDeviceOptionsTests: XCTestCase {
    func testAnOpenAIMeetingRunsOnThisMac() {
        let saved = TranscribeOptions(engine: .openAI, myName: "Alex", language: "auto",
                                      openAIModel: "gpt-4o-transcribe", localModel: "large-v3-turbo",
                                      summarize: true, summaryModel: "gpt-4o-mini", summaryEngine: "openai")
        let run = saved.onThisDevice
        XCTAssertEqual(run.engine, .local)
        XCTAssertEqual(run.localModel, LocalModel.defaultID)
        XCTAssertEqual(run.summaryEngine, SummaryEngine.apple.rawValue)
        XCTAssertEqual(saved.engine, .openAI, "the saved choice is what older meetings still read")
    }

    func testAppleSpeechAndWhisperAreLeftAlone() {
        let apple = TranscribeOptions(engine: .apple, myName: "Alex", language: "pt",
                                      openAIModel: "whisper-1", localModel: "large-v3-turbo",
                                      summarize: true, summaryModel: "gpt-4o-mini",
                                      summaryEngine: SummaryEngine.apple.rawValue)
        let run = apple.onThisDevice
        XCTAssertEqual(run.engine, .apple)
        XCTAssertEqual(run.localModel, "large-v3-turbo")
        XCTAssertEqual(run.summaryEngine, SummaryEngine.apple.rawValue)
    }

    func testAutoSummariesStayOnThisMac() {
        let options = TranscribeOptions(engine: .local, myName: "Alex", language: "auto",
                                        openAIModel: "whisper-1", localModel: LocalModel.defaultID,
                                        summarize: true, summaryModel: "gpt-4o-mini", summaryEngine: "auto")
        XCTAssertEqual(options.onThisDevice.summaryEngine, SummaryEngine.apple.rawValue)
    }
}
