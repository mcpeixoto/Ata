import XCTest

/// Welcome, what you record, the microphone, your name, a sentence, then Pro.
/// Snapshot launches never show the system permission prompt, so this does not
/// tap those buttons. `-AtaOnboardingMicGranted` walks the try-it step, which
/// a launch without the microphone would skip.
final class OnboardingFlowUITests: XCTestCase {
    @MainActor
    func testWalksSixStepsAndFinishes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "onboarding",
            "-AtaOnboardingMicGranted",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-onboarded", "YES",
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-onboarding-flow-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment = [
            "ATA_MEETINGS_DIR": folder.appendingPathComponent("meetings").path,
            "ATA_SUPPORT_DIR": folder.appendingPathComponent("support").path,
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Record it. Ata writes it up."].waitForExistence(timeout: 30),
                      "the onboarding did not come up")
        tap("onboarding-next", in: app)

        XCTAssertTrue(app.staticTexts["What will you record most?"].waitForExistence(timeout: 10))
        tap("onboarding-usecase-work", in: app)

        XCTAssertTrue(app.staticTexts["Let Ata hear the room"].waitForExistence(timeout: 10))
        tap("onboarding-next", in: app)

        XCTAssertTrue(app.staticTexts["Two questions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["onboarding-name"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-language"].waitForExistence(timeout: 10))
        tap("onboarding-next", in: app)

        XCTAssertTrue(app.staticTexts["Try it: say a sentence"].waitForExistence(timeout: 10))
        tap("onboarding-next", in: app)

        XCTAssertTrue(app.staticTexts["You're set"].waitForExistence(timeout: 10))
        let finish = app.buttons["onboarding-finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        finish.tap()

        let record = app.buttons["Record a conversation"]
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: record)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed,
                       "the sheet stayed up")
        app.terminate()
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 5), .completed)
        button.tap()
    }
}
