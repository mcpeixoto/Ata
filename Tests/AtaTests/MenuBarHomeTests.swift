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
        defaults.set("openai", forKey: Pref.engine)
        defaults.set("turbo", forKey: Pref.localModel)
        defaults.set(false, forKey: Pref.summarize)

        Pref.applyMenuBarHome(to: defaults)

        XCTAssertFalse(defaults.bool(forKey: Pref.dockIcon))
        XCTAssertTrue(defaults.bool(forKey: Pref.menuBarIcon))
        XCTAssertEqual(defaults.string(forKey: Pref.engine), Engine.local.rawValue)
        XCTAssertEqual(defaults.string(forKey: Pref.localModel), LocalModel.defaultID)
        XCTAssertTrue(defaults.bool(forKey: Pref.summarize))

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

/// OpenAI is gone: older settings, queued meetings and transcripts must survive that.
final class OpenAIRetiredTests: XCTestCase {
    private func suite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testOldSettingsAreClearedOnceAndTheDockChoiceIsKept() {
        let d = suite("ai.interactive.ata.tests.retire")
        d.set("openai", forKey: Pref.engine)
        d.set("large-v3-turbo", forKey: Pref.localModel)
        d.set("whisper-1", forKey: "openAIModel")
        d.set("gpt-4o-mini", forKey: "summaryModel")
        d.set("auto", forKey: "summaryEngine")
        d.set(true, forKey: Pref.dockIcon)

        XCTAssertTrue(Pref.retireOpenAI(to: d))

        XCTAssertEqual(d.string(forKey: Pref.engine), Engine.local.rawValue)
        for key in [Pref.localModel, "openAIModel", "summaryModel", "summaryEngine"] {
            XCTAssertNil(d.object(forKey: key), key)
        }
        XCTAssertTrue(d.bool(forKey: Pref.dockIcon), "this version does not decide about the Dock")

        d.set("apple", forKey: Pref.engine)
        XCTAssertFalse(Pref.retireOpenAI(to: d), "only once")
        XCTAssertEqual(d.string(forKey: Pref.engine), "apple")
    }

    func testWhisperLargeIsTheOnlyModel() {
        Pref.d.set("large-v3-turbo", forKey: Pref.localModel)
        defer { Pref.d.removeObject(forKey: Pref.localModel) }
        XCTAssertEqual(LocalModel.current.id, LocalModel.defaultID)
        XCTAssertEqual(LocalModel.defaultID, "large-v3-q5_0")
    }

    func testAMeetingQueuedWithOpenAIRunsOnThisDevice() {
        var m = Meeting(id: "t", startedAt: Date(), endedAt: nil, duration: nil, app: nil, status: .pending, error: nil)
        m.override = TranscribeOverride(engine: "openai", model: "gpt-4o-transcribe", language: "pt")
        let run = TranscribeOptions.current(for: m)
        XCTAssertEqual(run.engine, Engine.current)
        XCTAssertNotEqual(run.modelID, "gpt-4o-transcribe")
        XCTAssertEqual(run.language, "pt", "the language asked for still counts")
    }

    /// `costUSD` is required: drop it and a stored meeting no longer decodes,
    /// which makes the meeting disappear.
    func testAnOpenAIRecordStillDecodesAndIsNotCalledLocal() throws {
        let json = Data(#"""
        {"engine":"openai","model":"whisper-1","finishedAt":0,"audioSeconds":60,"processingSeconds":5,
         "costUSD":0.12,"words":10,"mySpeechSeconds":3,"othersSpeechSeconds":4}
        """#.utf8)
        let record = try JSONDecoder().decode(TranscriptionRecord.self, from: json)
        XCTAssertEqual(record.costUSD, 0.12)
        XCTAssertFalse(record.isLocal)

        let written = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        XCTAssertNotNil(object?["costUSD"], "older copies of Ata on the same iCloud need it")
    }

    func testAnOpenAITranscriptStillRendersWithItsOwnFooter() {
        let meeting = Meeting(id: "t", startedAt: Date(), endedAt: nil, duration: 60, app: nil, status: .done, error: nil)
        let stored = StoredTranscript(
            segments: [.init(start: 0, end: 1, text: "Olá", speaker: Speakers.me, words: nil)],
            coarse: true, summary: nil, engine: "openai", model: "gpt-4o-transcribe")
        let md = Transcriber.render(stored, meeting: meeting, names: { $0 })
        XCTAssertTrue(md.contains("gpt-4o-transcribe"), md)
        XCTAssertTrue(md.contains("OpenAI"), md)
        XCTAssertTrue(md.contains("Olá"), md)
    }
}

/// Where the transcription program comes from.
final class BundledWhisperTests: XCTestCase {
    func testTheAppScriptBundlesAndSignsWhisperBeforeTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let inner = try XCTUnwrap(script.range(of: #"--sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-cli""#))
        let outer = try XCTUnwrap(script.range(of: #"--sign "$SIGN_ID" "$APP""#, range: inner.upperBound..<script.endIndex))
        XCTAssertLessThan(inner.lowerBound, outer.lowerBound, "the app's signature must cover the signed program")
        let build = try String(contentsOf: root.appendingPathComponent("scripts/build-whisper.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("-DGGML_NATIVE=OFF"), "a build tuned to this chip would crash on an older Mac")
    }
}
