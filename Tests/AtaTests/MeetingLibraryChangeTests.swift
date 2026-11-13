@testable import Ata
import Combine
import XCTest

/// 3.5.2 froze the iPhone app on opening a meeting: the view told the model to
/// reload every time the library sent the same meeting again, the reload
/// changed the model, and that redrew the view, which subscribed again. The
/// model now reloads only when its meeting's copy in the library differs.
@MainActor
final class MeetingLibraryChangeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    func testTheSameMeetingAgainDoesNotReload() {
        // No such folder, so a reload finds nothing and never reaches the app's store.
        let model = MeetingModel(id: "no-such-meeting-\(UUID().uuidString)")
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }

        model.libraryChanged(nil)
        XCTAssertGreaterThan(changes, 0, "the first word from the library reloads")

        let afterFirst = changes
        model.libraryChanged(nil)
        model.libraryChanged(nil)
        XCTAssertEqual(changes, afterFirst, "the same copy again must not touch the model")
    }

    func testAChangedMeetingReloads() {
        let id = "no-such-meeting-\(UUID().uuidString)"
        let model = MeetingModel(id: id)
        model.libraryChanged(nil)
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        defer { watching.cancel() }

        var meeting = Meeting(id: id, startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil,
                              duration: nil, app: "Zoom", status: .pending, error: nil)
        model.libraryChanged(meeting)
        let afterAppearing = changes
        XCTAssertGreaterThan(afterAppearing, 0)

        meeting.status = .transcribing
        model.libraryChanged(meeting)
        XCTAssertGreaterThan(changes, afterAppearing)
    }
}
