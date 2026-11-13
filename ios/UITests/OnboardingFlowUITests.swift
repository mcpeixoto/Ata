import XCTest

/// Welcome, then the microphone, then name and language. Snapshot launches
/// never show the system permission prompt, so this does not tap those buttons.
final class OnboardingFlowUITests: XCTestCase {
    @MainActor
    func testWalksThreeStepsAndFinishes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "onboarding",
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
        tapNext(in: app)

        XCTAssertTrue(app.staticTexts["Let Ata hear the room"].waitForExistence(timeout: 10))
        tapNext(in: app)

        XCTAssertTrue(app.staticTexts["Two questions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["onboarding-name"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["onboarding-language"].waitForExistence(timeout: 10))
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
    private func tapNext(in app: XCUIApplication) {
        let next = app.buttons["onboarding-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: next)
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 5), .completed)
        next.tap()
    }
}
