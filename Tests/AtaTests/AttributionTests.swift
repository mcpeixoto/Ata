@testable import Ata
import XCTest

/// Apple Search Ads attribution: parse the AdServices record, ask once, and put
/// only the campaign id on the daily ping. The fixture client never opens a socket.
final class AttributionTests: XCTestCase {
    private let suite = "ai.interactive.ata.tests.attribution"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let monday = Date(timeIntervalSince1970: 1_793_000_000)

    /// Apple's sample record: attributed. Every field except campaignId is dropped.
    func testAttributedRecordKeepsOnlyTheCampaignId() {
        let body = """
        {"attribution":true,"orgId":1234567890,"campaignId":542370539,\
        "conversionType":"Download","clickDate":"2026-11-22T12:00Z","claimType":"Click",\
        "adGroupId":542317095,"countryOrRegion":"US","keywordId":87675432,"adId":542317136}
        """.data(using: .utf8)!
        XCTAssertEqual(Attribution.parse(body), .campaign("542370539"))
    }

    /// Apple's record when the install was not from a Search Ads campaign.
    func testUnattributedRecordIsOrganic() {
        let body = #"{"attribution":false}"#.data(using: .utf8)!
        XCTAssertEqual(Attribution.parse(body), .campaign(Attribution.organic))
    }

    /// A false attribution wins even if a campaign id came along with it.
    func testFalseAttributionIgnoresACampaignId() {
        let body = #"{"attribution":false,"campaignId":542370539}"#.data(using: .utf8)!
        XCTAssertEqual(Attribution.parse(body), .campaign(Attribution.organic))
    }

    func testErrorPayloadsAreRetried() {
        let bodies = [
            #"{"message":"invalid token"}"#,
            #"{"attribution":true}"#,
            #"{"attribution":true,"campaignId":true}"#,
            #"{"attribution":true,"campaignId":1.5}"#,
            "not json",
            "",
        ]
        for body in bodies {
            XCTAssertEqual(Attribution.parse(Data(body.utf8)), .retry, body)
        }
    }

    func testFixtureClientIsWhatGetsParsed() async {
        let body = #"{"attribution":true,"campaignId":542370539,"orgId":99}"#.data(using: .utf8)!
        let client = FixtureClient(body: body)
        let result = await Attribution.fetch(client: client)
        let posts = await client.posts
        XCTAssertEqual(result, .campaign("542370539"))
        XCTAssertEqual(posts, 1)
    }

    func testAFailingClientIsARetry() async {
        let result = await Attribution.fetch(client: ThrowingClient())
        XCTAssertEqual(result, .retry)
    }

    func testNothingIsAskedBeforeOnboardingOrWhileSharingIsOff() async {
        let client = FixtureClient(body: #"{"attribution":false}"#.data(using: .utf8)!)
        await Attribution.capture(defaults: defaults, client: client)
        let before = await client.tokens
        XCTAssertEqual(before, 0)
        XCTAssertNil(defaults.string(forKey: Pref.attributionCampaign))

        defaults.set(true, forKey: Pref.onboarded)
        defaults.set(false, forKey: Pref.shareUsage)
        await Attribution.capture(defaults: defaults, client: client)
        let after = await client.tokens
        XCTAssertEqual(after, 0)
    }

    func testACampaignIsStoredOnceAndNotAskedAgain() async {
        defaults.set(true, forKey: Pref.onboarded)
        let client = FixtureClient(body: #"{"attribution":true,"campaignId":542370539}"#.data(using: .utf8)!)
        await Attribution.capture(defaults: defaults, client: client)
        await Attribution.capture(defaults: defaults, client: client)
        let tokens = await client.tokens
        XCTAssertEqual(defaults.string(forKey: Pref.attributionCampaign), "542370539")
        XCTAssertEqual(tokens, 1)
    }

    func testOrganicIsStoredAndNotAskedAgain() async {
        defaults.set(true, forKey: Pref.onboarded)
        let client = FixtureClient(body: #"{"attribution":false}"#.data(using: .utf8)!)
        await Attribution.capture(defaults: defaults, client: client)
        await Attribution.capture(defaults: defaults, client: client)
        let tokens = await client.tokens
        XCTAssertEqual(defaults.string(forKey: Pref.attributionCampaign), "organic")
        XCTAssertEqual(tokens, 1)
    }

    /// A transport failure is not "organic". A few retries, then stop.
    func testFailuresRetryThenStopWithoutStoringACampaign() async {
        defaults.set(true, forKey: Pref.onboarded)
        let client = ThrowingClient()
        for _ in 0..<3 {
            await Attribution.capture(defaults: defaults, client: client)
        }
        await Attribution.capture(defaults: defaults, client: client)
        XCTAssertEqual(client.tokens, 3)
        XCTAssertNil(defaults.string(forKey: Pref.attributionCampaign))
    }

    func testStoredCampaignIsSentOnThePing() throws {
        defaults.set(true, forKey: Pref.onboarded)
        defaults.set("542370539", forKey: Pref.attributionCampaign)
        let due = try XCTUnwrap(Metrics.due(now: monday, defaults: defaults))
        XCTAssertEqual(due.payload.campaign, "542370539")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(due.payload)) as! [String: Any]
        XCTAssertEqual(json["campaign"] as? String, "542370539")
        XCTAssertNil(json["funnel"], "an empty funnel is absent, not null")
    }

    func testOrganicCampaignIsSentAsOrganic() throws {
        defaults.set(true, forKey: Pref.onboarded)
        defaults.set(Attribution.organic, forKey: Pref.attributionCampaign)
        let due = try XCTUnwrap(Metrics.due(now: monday, defaults: defaults))
        XCTAssertEqual(due.payload.campaign, "organic")
    }
}

/// Stands in for AdServices. Returns the fixture body and counts calls.
private actor FixtureClient: AdServicesClient {
    let body: Data
    private(set) var tokens = 0
    private(set) var posts = 0

    init(body: Data) { self.body = body }

    func attributionToken() async throws -> String {
        tokens += 1
        return "fixture-token"
    }

    func attributionData(token: String) async throws -> Data {
        XCTAssertEqual(token, "fixture-token")
        posts += 1
        return body
    }
}

private final class ThrowingClient: AdServicesClient, @unchecked Sendable {
    private(set) var tokens = 0

    func attributionToken() async throws -> String {
        tokens += 1
        throw URLError(.notConnectedToInternet)
    }

    func attributionData(token: String) async throws -> Data {
        XCTFail("no token, so no request")
        throw URLError(.notConnectedToInternet)
    }
}
