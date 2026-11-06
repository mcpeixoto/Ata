@testable import Ata
import XCTest

/// The daily anonymous ping: what it carries, when, and that "off" means off.
final class MetricsTests: XCTestCase {
    private let suite = "ai.interactive.ata.tests.metrics"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: Pref.onboarded)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let monday = Date(timeIntervalSince1970: 1_793_000_000)

    func testRecordingsAddUpUntilSent() {
        Metrics.recorded(seconds: 30 * 60, defaults: defaults)
        Metrics.recorded(seconds: 15 * 60, defaults: defaults)
        let due = Metrics.due(now: monday, defaults: defaults)
        XCTAssertEqual(due?.payload.meetings, 2)
        XCTAssertEqual(due?.payload.minutes, 45)

        // A recording that stops while the ping is in flight waits for tomorrow.
        Metrics.recorded(seconds: 60, defaults: defaults)
        Metrics.sent(due!, now: monday, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: Pref.metricsPendingMeetings), 1)
        XCTAssertEqual(defaults.double(forKey: Pref.metricsPendingSeconds), 60)
    }

    func testOncePerUTCDay() {
        let due = Metrics.due(now: monday, defaults: defaults)!
        Metrics.sent(due, now: monday, defaults: defaults)
        XCTAssertNil(Metrics.due(now: monday.addingTimeInterval(3600), defaults: defaults))
        let tomorrow = Metrics.due(now: monday.addingTimeInterval(86_400), defaults: defaults)
        XCTAssertEqual(tomorrow?.payload.id, due.payload.id, "the same install keeps its id")
        XCTAssertEqual(tomorrow?.payload.meetings, 0, "an idle day still counts the install")
    }

    func testOffSendsNothingAndForgets() {
        Metrics.recorded(seconds: 600, defaults: defaults)
        _ = Metrics.due(now: monday, defaults: defaults)
        XCTAssertNotNil(defaults.string(forKey: Pref.metricsID))

        defaults.set(false, forKey: Pref.shareUsage)
        Metrics.recorded(seconds: 600, defaults: defaults)
        XCTAssertNil(Metrics.due(now: monday, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: Pref.metricsID))
        XCTAssertEqual(defaults.integer(forKey: Pref.metricsPendingMeetings), 0)
        XCTAssertEqual(defaults.double(forKey: Pref.metricsPendingSeconds), 0)

        defaults.set(true, forKey: Pref.shareUsage)
        let again = Metrics.due(now: monday, defaults: defaults)
        XCTAssertEqual(again?.payload.meetings, 0, "nothing recorded while off is sent later")
    }

    func testNothingBeforeOnboarding() {
        defaults.set(false, forKey: Pref.onboarded)
        XCTAssertNil(Metrics.due(now: monday, defaults: defaults))
    }

    func testOwnIDNotTheDeviceID() {
        let id = Metrics.due(now: monday, defaults: defaults)!.payload.id
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertNotEqual(id, Device.id)
    }

    /// Anyone adding a field has to change this test, on purpose: the privacy
    /// page lists exactly these.
    func testPayloadCarriesExactlyTheseKeys() throws {
        let due = Metrics.due(now: monday, defaults: defaults)!
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(due.payload)) as! [String: Any]
        XCTAssertEqual(Set(json.keys),
                       ["id", "platform", "version", "build", "os", "locale", "meetings", "minutes"])
        XCTAssertEqual(json["platform"] as? String, "mac")
    }

    func testEndpoint() {
        let url = "https://example.workers.dev/v1/ping"
        XCTAssertNil(Metrics.endpoint(env: [:], plist: nil), "forks and tests send nothing")
        XCTAssertNil(Metrics.endpoint(env: [:], plist: ""))
        XCTAssertEqual(Metrics.endpoint(env: [:], plist: url)?.absoluteString, url)
        XCTAssertNil(Metrics.endpoint(env: ["ATA_MEETINGS_DIR": "/tmp/x"], plist: url), "scratch runs stay quiet")
        XCTAssertEqual(Metrics.endpoint(env: ["ATA_MEETINGS_DIR": "/tmp/x", "ATA_METRICS_URL": "http://localhost:8787/v1/ping"],
                                        plist: url)?.absoluteString, "http://localhost:8787/v1/ping")
    }

    func testLocaleIsLanguageAndRegionOnly() {
        XCTAssertEqual(Metrics.locale(Locale(identifier: "pt_PT@calendar=japanese;numbers=arab")), "pt-PT")
        XCTAssertEqual(Metrics.locale(Locale(identifier: "en")), "en")
    }

    func testDayIsUTC() {
        XCTAssertEqual(Metrics.day(Date(timeIntervalSince1970: 0)), "1970-01-01")
        XCTAssertEqual(Metrics.day(Date(timeIntervalSince1970: 86_399)), "1970-01-01")
        XCTAssertEqual(Metrics.day(Date(timeIntervalSince1970: 86_400)), "1970-01-02")
    }
}
