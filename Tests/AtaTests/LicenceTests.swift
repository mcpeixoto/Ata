@testable import Ata
import XCTest

/// The Mac licence: a key the Stripe Worker accepts, kept in the support
/// folder, which unlocks Ata Pro without a call to the App Store.
@MainActor
final class LicenceTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private final class FakeAPI: LicenceAPI {
        var calls: [String] = []
        var lastKey: String?
        var lastInstanceID: String?
        var reply = LicenceReply(ok: true, instanceID: "11111111-1111-1111-1111-111111111111",
                                 status: .active, plan: "yearly", expiresAt: nil, error: nil, httpStatus: 200)
        var thrown: Error?

        func activate(key: String, instanceName: String) async throws -> LicenceReply {
            calls.append("activate")
            lastKey = key
            if let thrown { throw thrown }
            return reply
        }

        func validate(key: String, instanceID: String) async throws -> LicenceReply {
            calls.append("validate")
            lastKey = key
            lastInstanceID = instanceID
            if let thrown { throw thrown }
            return reply
        }

        func deactivate(key: String, instanceID: String) async throws -> LicenceReply {
            calls.append("deactivate")
            lastKey = key
            lastInstanceID = instanceID
            if let thrown { throw thrown }
            return reply
        }

        func recover(email: String) async throws {
            calls.append("recover")
            if let thrown { throw thrown }
        }
    }

    private var root: URL!
    private var clock: Clock!
    private var api: FakeAPI!
    private var access: ProAccess!
    private var store: LicenceStore!
    private let key = "ATA-1111-2222-3333-4444"

    override func setUp() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-licence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("ATA_MEETINGS_DIR", root.appendingPathComponent("meetings").path, 1)
        setenv("ATA_SUPPORT_DIR", root.appendingPathComponent("support").path, 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        clock = Clock(calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 12))!)
        api = FakeAPI()
        access = ProAccess()
        store = LicenceStore(api: api,
                             fileURL: root.appendingPathComponent("support/licence.json"),
                             access: access,
                             instanceName: "Test Mac",
                             now: { [clock] in clock?.date ?? Date(timeIntervalSince1970: 0) })
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        unsetenv("ATA_MEETINGS_DIR")
        unsetenv("ATA_SUPPORT_DIR")
        store = nil
    }

    private var file: URL { root.appendingPathComponent("support/licence.json") }

    /// A key Stripe still calls past_due unlocks. Canceled and refunded do not.
    func testCanceledAndRefundedAreNotProAndPastDueIs() async {
        api.reply.status = .pastDue
        api.reply.ok = true
        await store.activate(rawKey: key)
        XCTAssertTrue(access.isPro)
        XCTAssertTrue(access.sources.contains(.licence))

        access.setLicence(active: false)
        api.reply.status = .canceled
        api.reply.ok = false
        api.reply.httpStatus = 403
        let rejected = LicenceStore(api: api, fileURL: root.appendingPathComponent("support/other.json"),
                                    access: access, instanceName: "Test Mac",
                                    now: { [clock] in clock?.date ?? Date() })
        await rejected.activate(rawKey: key)
        XCTAssertFalse(access.isPro)
        XCTAssertEqual(rejected.notice, .expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("support/other.json").path))

        api.reply.status = .refunded
        await rejected.activate(rawKey: key)
        XCTAssertFalse(access.isPro)
        XCTAssertEqual(rejected.notice, .expired)
    }

    /// The success page opens ata://licence?key= and the key is activated.
    func testLicenceURLIsParsedAndActivated() async {
        let url = URL(string: "ata://licence?key=ata-iiii-2222-3333-444o")!
        await store.activate(url: url)
        XCTAssertEqual(api.calls, ["activate"])
        XCTAssertEqual(api.lastKey, "ATA-1111-2222-3333-4440")
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(store.notice, nil)
    }

    /// A key that cannot be one never leaves the Mac.
    func testMalformedKeyNeverCallsTheNetwork() async {
        await store.activate(rawKey: "hello")
        await store.activate(rawKey: "ATA-1111-2222-3333-444U")
        await store.activate(url: URL(string: "ata://licence?key=nope")!)
        await store.activate(url: URL(string: "https://example.com/?key=\(key)")!)
        XCTAssertEqual(api.calls, [])
        XCTAssertFalse(access.isPro)
        XCTAssertEqual(store.notice, .malformed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// No server: still Pro until 30 days after the last answer, and not after.
    func testOfflineGraceIsThirtyDays() async throws {
        await store.activate(rawKey: key)
        let saved = try Data(contentsOf: file)
        api.thrown = URLError(.cannotConnectToHost)
        api.calls.removeAll()

        clock.date = clock.date.addingTimeInterval(30 * 24 * 60 * 60 - 1)
        await store.restore()
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(try Data(contentsOf: file), saved)

        clock.date = clock.date.addingTimeInterval(1)
        await store.restore()
        XCTAssertFalse(access.isPro)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    /// The Worker is asked again only once a week, and a success moves that week.
    func testRevalidationWaitsSevenDays() async {
        await store.activate(rawKey: key)
        api.calls.removeAll()

        clock.date = clock.date.addingTimeInterval(7 * 24 * 60 * 60 - 1)
        await store.restore()
        XCTAssertEqual(api.calls, [])

        clock.date = clock.date.addingTimeInterval(1)
        await store.restore()
        XCTAssertEqual(api.calls, ["validate"])
        XCTAssertEqual(api.lastInstanceID, "11111111-1111-1111-1111-111111111111")
        XCTAssertTrue(access.isPro)
        await store.restore()
        XCTAssertEqual(api.calls, ["validate"])
        XCTAssertTrue(access.isPro)
    }

    /// A timeout, or a second key that never gets an answer, leaves the saved one.
    func testAFailedNetworkCallKeepsAValidLicence() async throws {
        await store.activate(rawKey: key)
        let saved = try Data(contentsOf: file)
        api.thrown = URLError(.timedOut)
        api.calls.removeAll()

        clock.date = clock.date.addingTimeInterval(8 * 24 * 60 * 60)
        await store.restore()
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(try Data(contentsOf: file), saved)

        await store.activate(rawKey: "ATA-2222-3333-4444-5555")
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(store.notice, .unreachable)
        XCTAssertEqual(try Data(contentsOf: file), saved)
    }

    /// The three server reasons the paywall can say, and a rate limit is none of them.
    func testServerReasonsMapToThreeMessages() {
        XCTAssertEqual(LicencePolicy.notice(for: reply(error: "not_found", code: 404)), .notFound)
        XCTAssertEqual(LicencePolicy.notice(for: reply(error: "too_many_instances", code: 409)), .tooManyMacs)
        XCTAssertEqual(LicencePolicy.notice(for: reply(code: 403, state: .canceled)), .expired)
        XCTAssertEqual(LicencePolicy.notice(for: reply(code: 403, state: .refunded)), .expired)
        XCTAssertNil(LicencePolicy.notice(for: reply(error: "rate_limited", code: 429)))
    }

    /// What the Worker actually sends, including a lifetime key with no end.
    func testTheWorkerJSONDecodes() throws {
        let pastDue = """
        {"ok":true,"instance_id":"11111111-1111-1111-1111-111111111111","status":"past_due","plan":"yearly","expires_at":"2026-12-01T00:00:00Z"}
        """.data(using: .utf8)!
        let decoded = try LicenceWire.reply(from: pastDue, status: 200)
        XCTAssertEqual(decoded.status, .pastDue)
        XCTAssertEqual(decoded.instanceID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(decoded.plan, "yearly")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(decoded.expiresAt, formatter.date(from: "2026-12-01T00:00:00Z"))

        let lifetime = """
        {"ok":true,"instance_id":"11111111-1111-1111-1111-111111111111","status":"active","plan":"lifetime","expires_at":null}
        """.data(using: .utf8)!
        XCTAssertNil(try LicenceWire.reply(from: lifetime, status: 200).expiresAt)
    }

    /// The key file is the owner's to read, not the rest of the Mac's.
    func testTheLicenceFileIsOwnerReadableOnly() async throws {
        await store.activate(rawKey: key)
        let raw = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(raw & 0o777, 0o600)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        XCTAssertEqual(json?["key"] as? String, key)
        XCTAssertEqual(json?["instanceID"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(json?["status"] as? String, "active")
    }

    /// No URL, no web purchase; the shipped plist names an https Worker. The price is the string in the table, never a division.
    func testAnEmptyLicenceURLHidesThePurchaseAndThePriceIsNotComputed() throws {
        XCTAssertNil(MacProOffer.base(nil))
        XCTAssertNil(MacProOffer.base(""))
        XCTAssertNil(MacProOffer.base("   "))
        XCTAssertNil(MacProOffer.base("http://insecure.example"))
        let base = try XCTUnwrap(MacProOffer.base("https://ata-licence.example"))
        XCTAssertEqual(MacProOffer.checkout(base: base, plan: .yearly)?.absoluteString,
                       "https://ata-licence.example/buy?plan=yearly")
        XCTAssertEqual(MacProOffer.price(currency: "EUR", table: ["USD": "$3.75/mo", "EUR": "3,75 €/mês"]),
                       "3,75 €/mês")
        XCTAssertEqual(MacProOffer.price(currency: "GBP", table: ["USD": "$3.75/mo"]), "$3.75/mo")
        XCTAssertNil(MacProOffer.price(currency: "GBP", table: [:]))

        let plistURL = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: plistURL))
        XCTAssertEqual(MacProOffer.base(plist["AtaLicenceURL"] as? String)?.scheme, "https")
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("ata"))
    }

    /// Pro is the only thing that lifts the 300 minutes.
    func testTheLimitBlocksOnlyWhenNotPro() {
        XCTAssertTrue(FreeQuota.blocks(isPro: false, usedMinutes: 300))
        XCTAssertTrue(FreeQuota.blocks(isPro: false, usedMinutes: 301))
        XCTAssertFalse(FreeQuota.blocks(isPro: true, usedMinutes: 500))
        XCTAssertFalse(FreeQuota.blocks(isPro: false, usedMinutes: 299))
    }

    /// The month turns on the 1st, which the paywall names.
    func testTheAllowanceResetsOnTheFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22))!
        let reset = MacProOffer.nextReset(now: now, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day], from: reset)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 12)
        XCTAssertEqual(parts.day, 1)
    }

    /// Settings says which door unlocked the Mac, or how many free minutes are gone.
    func testTheStatusLineNamesTheSource() {
        XCTAssertEqual(ProStatus.line(licenceActive: false, licenceExpires: nil, viaPhone: false, used: 212, limit: 300),
                       "Free · 212 of 300 min")
        XCTAssertEqual(ProStatus.line(licenceActive: false, licenceExpires: nil, viaPhone: true, used: 300, limit: 300),
                       "Active via iPhone")
        XCTAssertEqual(ProStatus.line(licenceActive: true, licenceExpires: nil, viaPhone: true, used: 300, limit: 300),
                       "Active via licence")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expires = calendar.date(from: DateComponents(year: 2027, month: 1, day: 5))!
        let dated = ProStatus.line(licenceActive: true, licenceExpires: expires, viaPhone: false,
                                   used: 0, limit: 300, locale: Locale(identifier: "en_GB"))
        XCTAssertTrue(dated.hasPrefix("Active via licence until "))
        XCTAssertTrue(dated.contains("2027"))
    }

    /// At the limit the meeting alert no longer offers Record.
    func testTheLimitNotificationDoesNotOfferRecord() {
        let blocked = Notifier.detectedNotice(app: "Zoom", atLimit: true)
        XCTAssertEqual(blocked.body, "You've used this month's free minutes")
        XCTAssertFalse(blocked.offersRecord)
        let open = Notifier.detectedNotice(app: "Zoom", atLimit: false)
        XCTAssertEqual(open.body, "Record and transcribe this meeting?")
        XCTAssertTrue(open.offersRecord)
    }

    private func reply(error: String? = nil, code: Int, state: LicenceStatus? = nil) -> LicenceReply {
        LicenceReply(ok: false, instanceID: nil, status: state, plan: nil, expiresAt: nil,
                     error: error, httpStatus: code)
    }
}
