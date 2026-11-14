@testable import Ata
import Combine
import XCTest

/// Decisions from the 3.7.2 UI sweep that can be answered without a window.
@MainActor
final class UISweepTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    func testDeleteAndRetryWaitWhileAudioIsStillBeingSaved() {
        XCTAssertFalse(MeetingCommands.canDelete(id: "a", status: .done, currentID: nil,
                                                 transcribingID: nil, savingAudio: true))
        XCTAssertFalse(MeetingCommands.canDelete(id: "a", status: .recording, currentID: nil,
                                                 transcribingID: nil, savingAudio: false))
        XCTAssertFalse(MeetingCommands.canDelete(id: "a", status: .done, currentID: "a",
                                                 transcribingID: nil, savingAudio: false))
        XCTAssertFalse(MeetingCommands.canDelete(id: "a", status: .done, currentID: nil,
                                                 transcribingID: "a", savingAudio: false))
        XCTAssertTrue(MeetingCommands.canDelete(id: "a", status: .done, currentID: "b",
                                                transcribingID: nil, savingAudio: false))

        XCTAssertFalse(MeetingCommands.canRetry(hasAudio: true, isPlaceholder: false, id: "a",
                                                currentID: nil, transcribingID: nil, summarizingID: nil,
                                                savingAudio: true, canClaim: true))
        XCTAssertFalse(MeetingCommands.canRetry(hasAudio: false, isPlaceholder: false, id: "a",
                                                currentID: nil, transcribingID: nil, summarizingID: nil,
                                                savingAudio: false, canClaim: true))
        XCTAssertFalse(MeetingCommands.canRetry(hasAudio: true, isPlaceholder: true, id: "a",
                                                currentID: nil, transcribingID: nil, summarizingID: "a",
                                                savingAudio: false, canClaim: true))
        XCTAssertFalse(MeetingCommands.canRetry(hasAudio: true, isPlaceholder: false, id: "a",
                                                currentID: nil, transcribingID: nil, summarizingID: nil,
                                                savingAudio: false, canClaim: false))
        XCTAssertTrue(MeetingCommands.canRetry(hasAudio: true, isPlaceholder: false, id: "a",
                                               currentID: nil, transcribingID: nil, summarizingID: nil,
                                               savingAudio: false, canClaim: true))
    }

    func testReloadingAnUnchangedVoiceLibraryDoesNotPublish() {
        let people = PeopleModel.shared
        people.reload()
        let published = expectation(description: "voices published")
        published.isInverted = true
        let watching = people.$voices.dropFirst().sink { _ in published.fulfill() }
        people.reload()
        wait(for: [published], timeout: 0.3)
        watching.cancel()
    }

    func testAFocusedRedrawKeepsThisMeetingAndDefersTheRest() {
        let parts = PeopleModel.split(["a", "b", "a"], focus: "a")
        XCTAssertEqual(parts.now, ["a", "a"])
        XCTAssertEqual(parts.later, ["b"])
        XCTAssertEqual(PeopleModel.split([], focus: "a").now, [])
        XCTAssertEqual(PeopleModel.split(["b"], focus: "a").later, ["b"])
    }

    func testAnInstallRefusesWhileRecordingTranscribingOrFinishing() {
        XCTAssertFalse(UpdateInstall.allowed(recording: true, transcribing: false, finishing: false))
        XCTAssertFalse(UpdateInstall.allowed(recording: false, transcribing: true, finishing: false))
        XCTAssertFalse(UpdateInstall.allowed(recording: false, transcribing: false, finishing: true))
        XCTAssertTrue(UpdateInstall.allowed(recording: false, transcribing: false, finishing: false))
        let state = UpdateInstall.refused(version: "3.7.2", notes: "notes")
        guard case .available(let version, let notes) = state else {
            return XCTFail("a refused install keeps the offer, \(state)")
        }
        XCTAssertEqual(version, "3.7.2")
        XCTAssertEqual(notes, "notes")
    }

    func testSystemAudioWaitsUntilTheQueueIsIdle() {
        XCTAssertTrue(SetupModel.mayRestart(idle: true, transcribing: false))
        XCTAssertFalse(SetupModel.mayRestart(idle: false, transcribing: false))
        XCTAssertFalse(SetupModel.mayRestart(idle: true, transcribing: true))
        XCTAssertFalse(SetupModel.mayRestart(idle: false, transcribing: true))
    }

    func testQuitWaitsForARecordingOrForFilesStillClosing() {
        XCTAssertTrue(QuitShutdown.waits(recording: true, finishing: false))
        XCTAssertTrue(QuitShutdown.waits(recording: false, finishing: true))
        XCTAssertFalse(QuitShutdown.waits(recording: false, finishing: false))
    }

    func testAShorterAudioWindowAsksOnlyWhenSomethingWouldGo() {
        XCTAssertFalse(AudioRetention.isShorter(7, than: 7))
        XCTAssertFalse(AudioRetention.isShorter(30, than: 7))
        XCTAssertFalse(AudioRetention.isShorter(0, than: 30), "forever is not shorter")
        XCTAssertTrue(AudioRetention.isShorter(7, than: 0))
        XCTAssertTrue(AudioRetention.isShorter(30, than: 90))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = AudioRetention.Item(startedAt: now.addingTimeInterval(-40 * 86_400), isMine: true,
                                      isDone: true, hasKeptAudio: true, repairing: false)
        let recent = AudioRetention.Item(startedAt: now.addingTimeInterval(-2 * 86_400), isMine: true,
                                         isDone: true, hasKeptAudio: true, repairing: false)
        let someoneElses = AudioRetention.Item(startedAt: old.startedAt, isMine: false, isDone: true,
                                               hasKeptAudio: true, repairing: false)
        let stillRecording = AudioRetention.Item(startedAt: old.startedAt, isMine: true, isDone: false,
                                                 hasKeptAudio: true, repairing: false)
        XCTAssertTrue(AudioRetention.wouldDelete(days: 30, items: [old], now: now))
        XCTAssertFalse(AudioRetention.wouldDelete(days: 30, items: [recent], now: now))
        XCTAssertFalse(AudioRetention.wouldDelete(days: 0, items: [old], now: now))
        XCTAssertFalse(AudioRetention.wouldDelete(days: 30, items: [someoneElses, stillRecording], now: now))
        XCTAssertTrue(AudioRetention.needsConfirmation(from: 0, to: 30, items: [old], now: now))
        XCTAssertFalse(AudioRetention.needsConfirmation(from: 0, to: 30, items: [recent], now: now))
        XCTAssertFalse(AudioRetention.needsConfirmation(from: 7, to: 90, items: [old], now: now))
    }

    func testStartingAnotherMeetingPausesTheOnePlaying() {
        // Held: an identifier does not keep the player, and a freed one can be reused.
        let playing = MeetingPlayer()
        let next = MeetingPlayer()
        XCTAssertTrue(NowPlaying.shouldPause(current: ObjectIdentifier(playing), next: ObjectIdentifier(next)))
        XCTAssertFalse(NowPlaying.shouldPause(current: ObjectIdentifier(playing), next: ObjectIdentifier(playing)))
        XCTAssertFalse(NowPlaying.shouldPause(current: nil, next: ObjectIdentifier(next)))
    }

    func testThePlayButtonFollowsThePlayerNotTheLastTap() {
        XCTAssertFalse(MeetingPlayer.showsPlaying(.paused))
        XCTAssertTrue(MeetingPlayer.showsPlaying(.playing))
        XCTAssertTrue(MeetingPlayer.showsPlaying(.waitingToPlayAtSpecifiedRate))
    }

    func testInsightsOpensOnce() {
        XCTAssertTrue(InsightsEntrance.animates(already: false))
        XCTAssertFalse(InsightsEntrance.animates(already: true))
    }

    func testPendingNotesAreWrittenOnlyWhileTheFolderRemains() {
        XCTAssertTrue(MeetingNotes.shouldWritePending(folderExists: true, changed: true))
        XCTAssertFalse(MeetingNotes.shouldWritePending(folderExists: false, changed: true))
        XCTAssertFalse(MeetingNotes.shouldWritePending(folderExists: true, changed: false))
    }

    func testDeletingTheMeetingFileKeepsNotesTypedInTheWindow() throws {
        let meeting = try Meeting.new(app: nil)
        Library.save(meeting)
        let model = MeetingModel(id: meeting.id)
        model.notes = "last line"
        try FileManager.default.removeItem(at: meeting.metaURL)
        model.reload()
        XCTAssertEqual(try String(contentsOf: meeting.notesURL, encoding: .utf8), "last line")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.dir.path))
    }

    func testATrashedMeetingDoesNotComeBackForItsNotes() throws {
        let meeting = try Meeting.new(app: nil)
        Library.save(meeting)
        let model = MeetingModel(id: meeting.id)
        model.notes = "last line"
        try FileManager.default.removeItem(at: meeting.dir)
        model.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: meeting.dir.path))
    }
}
