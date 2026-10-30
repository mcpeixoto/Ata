@testable import Ata
import XCTest

/// Copying the transcript or the notes used to give no sign it had worked, and
/// the follow-up draft's confirmation was drawn as a warning. A notice now says
/// so, apart from `message`, and goes away by itself.
@MainActor
final class MeetingNoticeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    /// No such folder, so the model loads nothing and never reaches the app's store.
    private func model() -> MeetingModel {
        MeetingModel(id: "no-such-meeting-\(UUID().uuidString)")
    }

    func testANoticeShowsAndThenGoesAway() {
        let m = model()
        m.say("Notes copied.", for: 0.05)
        XCTAssertEqual(m.notice, "Notes copied.")
        XCTAssertNil(m.message, "a success is not a warning")

        let gone = expectation(description: "notice cleared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(m.notice)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 2)
    }

    func testANewNoticeIsNotClearedByTheOldOnesTimer() {
        let m = model()
        m.say("Transcript copied.", for: 0.05)
        m.say("MP3 saved.", for: 5)

        let later = expectation(description: "old timer passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertEqual(m.notice, "MP3 saved.")
            later.fulfill()
        }
        wait(for: [later], timeout: 2)
    }
}
