#if os(macOS)
import Foundation

/// What the licence Worker last said about a key. `active` and `past_due` unlock;
/// `canceled` and `refunded` do not. The Worker already folds Stripe's longer list
/// into these four, and keeps a subscription unlocking for three days after the period.
enum LicenceStatus: String, Codable {
    case active
    case pastDue = "past_due"
    case canceled
    case refunded

    var unlocks: Bool { self == .active || self == .pastDue }
}

/// One Mac's activation, in `licence.json` in the support folder. Not the keychain:
/// reading the keychain can raise a prompt, and this file is opened at launch.
struct LicenceFile: Codable, Equatable {
    var key: String
    var instanceID: String
    var lastValidated: Date
    var status: LicenceStatus
    var expiresAt: Date?
}

/// Why a key was refused, in the words the paywall shows. A timeout is not one of
/// these: it leaves whatever was already saved.
enum LicenceNotice: Equatable {
    case notFound
    case expired
    case tooManyMacs
    case malformed
    case unreachable
    case sent

    var message: String {
        switch self {
        case .notFound: return L("That licence key was not found.")
        case .expired: return L("That licence key has expired.")
        case .tooManyMacs: return L("That licence key is already in use on too many Macs.")
        case .malformed: return L("That doesn't look like a licence key.")
        case .unreachable: return L("Ata could not reach the licence server. Your licence was left as it is.")
        case .sent: return L("If a licence is registered to that email, the key is on its way.")
        }
    }
}

struct LicenceReply: Equatable {
    var ok: Bool
    var instanceID: String?
    var status: LicenceStatus?
    var plan: String?
    var expiresAt: Date?
    var error: String?
    var httpStatus: Int
}

enum LicenceTransport: Error {
    case unavailable
    case badResponse
}

protocol LicenceAPI: AnyObject {
    func activate(key: String, instanceName: String) async throws -> LicenceReply
    func validate(key: String, instanceID: String) async throws -> LicenceReply
    func deactivate(key: String, instanceID: String) async throws -> LicenceReply
    func recover(email: String) async throws
}

/// The key the success page puts in `ata://licence?key=`, and how long a saved
/// answer keeps unlocking when the Mac is offline.
enum LicencePolicy {
    static let revalidateAfter: TimeInterval = 7 * 24 * 60 * 60
    static let offlineGrace: TimeInterval = 30 * 24 * 60 * 60

    /// Crockford base32, the same alphabet the Worker uses. I and L are read as 1,
    /// O as 0, so a key someone misread still matches.
    static func normaliseKey(_ input: String) -> String? {
        if input.count > 64 { return nil }
        let folded = input.uppercased()
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map { Character($0) }
        var text = String(folded)
        text = text.replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "O", with: "0")
        if text.hasPrefix("ATA-") {
            text.removeFirst(4)
        } else if text.hasPrefix("ATA") {
            text.removeFirst(3)
        }
        text = text.replacingOccurrences(of: "-", with: "")
        guard text.count == 16 else { return nil }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        guard text.allSatisfy({ alphabet.contains($0) }) else { return nil }
        let chars = Array(text)
        func group(_ start: Int) -> String { String(chars[start..<start + 4]) }
        return "ATA-\(group(0))-\(group(4))-\(group(8))-\(group(12))"
    }

    static func isActive(_ file: LicenceFile, now: Date) -> Bool {
        guard file.status.unlocks else { return false }
        return now < file.lastValidated.addingTimeInterval(offlineGrace)
    }

    static func shouldRevalidate(_ file: LicenceFile, now: Date) -> Bool {
        now.timeIntervalSince(file.lastValidated) >= revalidateAfter
    }

    /// The three messages the paywall shows for a key the Worker refused.
    /// Nil when the answer is not one of those refusals (a rate limit, a success).
    static func notice(for reply: LicenceReply) -> LicenceNotice? {
        switch reply.error {
        case "not_found": return .notFound
        case "too_many_instances": return .tooManyMacs
        case "bad_key": return .malformed
        default: break
        }
        guard !reply.ok else { return nil }
        if reply.status == .canceled || reply.status == .refunded || reply.httpStatus == 403 {
            return .expired
        }
        return nil
    }

    enum Decision {
        case keep
        case forget
        case update(LicenceFile)
    }

    /// What a validate answer does to the file already on disk. A transport
    /// failure never reaches here, so it cannot take the file away.
    static func decision(_ reply: LicenceReply, file: LicenceFile, now: Date) -> Decision {
        if reply.error == "not_found" || reply.error == "unknown_instance" { return .forget }
        guard let status = reply.status else { return .keep }
        var copy = file
        copy.status = status
        copy.expiresAt = reply.expiresAt
        copy.lastValidated = now
        return .update(copy)
    }
}

enum LicenceWire {
    private struct Body: Decodable {
        var ok: Bool?
        var instance_id: String?
        var status: String?
        var plan: String?
        var expires_at: String?
        var error: String?
    }

    static func reply(from data: Data, status: Int) throws -> LicenceReply {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw LicenceTransport.badResponse
        }
        return LicenceReply(ok: body.ok ?? false,
                            instanceID: body.instance_id,
                            status: body.status.flatMap(LicenceStatus.init(rawValue:)),
                            plan: body.plan,
                            expiresAt: date(body.expires_at),
                            error: body.error,
                            httpStatus: status)
    }

    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Talks to the Worker at `AtaLicenceURL`. An empty URL fails before any request,
/// which is how a build ships before the Worker address is filled in.
final class LicenceHTTP: LicenceAPI {
    func activate(key: String, instanceName: String) async throws -> LicenceReply {
        try await post("/v1/activate", ["key": key, "instance_name": instanceName])
    }

    func validate(key: String, instanceID: String) async throws -> LicenceReply {
        try await post("/v1/validate", ["key": key, "instance_id": instanceID])
    }

    func deactivate(key: String, instanceID: String) async throws -> LicenceReply {
        try await post("/v1/deactivate", ["key": key, "instance_id": instanceID])
    }

    func recover(email: String) async throws {
        let (_, status) = try await send("/v1/recover", ["email": email])
        guard (200..<300).contains(status) else { throw LicenceTransport.badResponse }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> LicenceReply {
        let (data, status) = try await send(path, body)
        return try LicenceWire.reply(from: data, status: status)
    }

    private func send(_ path: String, _ body: [String: String]) async throws -> (Data, Int) {
        guard let base = MacProOffer.baseURL, let url = MacProOffer.endpoint(base: base, path: path) else {
            throw LicenceTransport.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LicenceTransport.badResponse }
        return (data, http.statusCode)
    }
}

/// Where the Mac paywall sends someone, and what it is allowed to say the price is.
enum MacProOffer {
    /// The yearly plan, shown as a per-month price. The string comes from the
    /// Info.plist for that currency; the app never divides a yearly price.
    static func checkout(base: URL, plan: Plan) -> URL? {
        var root = base.absoluteString
        if root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + "/buy?plan=\(plan.rawValue)")
    }

    static func endpoint(base: URL, path: String) -> URL? {
        var root = base.absoluteString
        if root.hasSuffix("/") { root.removeLast() }
        let tail = path.hasPrefix("/") ? path : "/" + path
        return URL(string: root + tail)
    }

    static func base(_ raw: String?) -> URL? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, let url = URL(string: text),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static var baseURL: URL? {
        base(Bundle.main.object(forInfoDictionaryKey: "AtaLicenceURL") as? String)
    }

    /// False until `AtaLicenceURL` is filled in. The purchase button and the key
    /// field stay hidden, and only the iPhone route is offered.
    static var isConfigured: Bool { baseURL != nil }

    static func price(currency: String, table: [String: String]) -> String? {
        let clean = table.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let match = clean[currency], !match.isEmpty { return match }
        if let dollars = clean["USD"], !dollars.isEmpty { return dollars }
        return nil
    }

    static var displayPrice: String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AtaProPrice") as? [String: Any] ?? [:]
        var table: [String: String] = [:]
        for (key, value) in raw {
            if let text = value as? String { table[key] = text }
        }
        let code = Locale.current.currency?.identifier ?? "USD"
        return price(currency: code, table: table)
    }

    static var checkoutURL: URL? {
        guard let baseURL, displayPrice != nil else { return nil }
        return checkout(base: baseURL, plan: .yearly)
    }

    /// The first of next month, when the free minutes start again.
    static func nextReset(now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let start = calendar.date(from: parts) ?? now
        return calendar.date(byAdding: .month, value: 1, to: start) ?? now
    }
}

/// The Settings line: free with a count, or which purchase unlocked this Mac.
enum ProStatus {
    static func line(licenceActive: Bool, licenceExpires: Date?, viaPhone: Bool,
                     used: Int, limit: Int, locale: Locale = .current) -> String {
        if licenceActive {
            if let licenceExpires {
                let day = licenceExpires.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
                return L("Active via licence until %@", day)
            }
            return L("Active via licence")
        }
        if viaPhone { return L("Active via iPhone") }
        return L("Free · %d of %d min", used, limit)
    }
}

/// The saved licence, and the calls that change it. A failed call never deletes
/// a file that was already unlocking this Mac.
@MainActor
final class LicenceStore: ObservableObject {
    static let shared = LicenceStore()

    @Published private(set) var isActive = false
    @Published private(set) var expiresAt: Date?
    @Published private(set) var activating = false
    @Published var notice: LicenceNotice?
    @Published var revealKeyField = false

    let fileURL: URL
    private let api: LicenceAPI
    private let access: ProAccess
    private let instanceName: String
    private let now: () -> Date

    init(api: LicenceAPI = LicenceHTTP(),
         fileURL: URL = Paths.supportDir.appendingPathComponent("licence.json"),
         access: ProAccess? = nil,
         instanceName: String = Device.name,
         now: @escaping () -> Date = Date.init) {
        self.api = api
        self.fileURL = fileURL
        // Resolved here, not as a default argument: defaults are evaluated outside
        // the main actor, where `ProAccess.shared` cannot be read (Swift 6).
        self.access = access ?? .shared
        self.instanceName = instanceName
        self.now = now
    }

    func presentKeyField() { revealKeyField = true }

    /// Reads the file and unlocks immediately. The network check, if one is due,
    /// happens after, and a failure leaves this result in place.
    func applySaved() {
        apply(load())
    }

    func revalidateIfDue() async {
        guard let file = load(), LicencePolicy.shouldRevalidate(file, now: now()) else { return }
        await revalidate(file)
    }

    func restore() async {
        applySaved()
        await revalidateIfDue()
    }

    func activate(url: URL) async {
        guard url.scheme?.lowercased() == "ata", url.host?.lowercased() == "licence" else { return }
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "key" })?.value,
              LicencePolicy.normaliseKey(raw) != nil else {
            notice = .malformed
            return
        }
        await activate(rawKey: raw)
    }

    func activate(rawKey: String) async {
        guard let key = LicencePolicy.normaliseKey(rawKey) else {
            notice = .malformed
            return
        }
        activating = true
        defer { activating = false }
        do {
            let reply = try await api.activate(key: key, instanceName: instanceName)
            if let reason = LicencePolicy.notice(for: reply) {
                notice = reason
                return
            }
            guard reply.ok, let id = reply.instanceID, !id.isEmpty,
                  let status = reply.status, status.unlocks else {
                notice = .unreachable
                return
            }
            let file = LicenceFile(key: key, instanceID: id, lastValidated: now(),
                                   status: status, expiresAt: reply.expiresAt)
            try save(file)
            notice = nil
            apply(file)
        } catch {
            notice = .unreachable
        }
    }

    func deactivate() async {
        guard let file = load() else {
            apply(nil)
            return
        }
        do {
            let reply = try await api.deactivate(key: file.key, instanceID: file.instanceID)
            if reply.httpStatus >= 500 || reply.error == "rate_limited" {
                notice = .unreachable
                return
            }
        } catch {
            notice = .unreachable
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
        notice = nil
        apply(nil)
    }

    func recover(email: String) async {
        do {
            try await api.recover(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
            notice = .sent
        } catch {
            notice = .unreachable
        }
    }

    private func revalidate(_ file: LicenceFile) async {
        do {
            let reply = try await api.validate(key: file.key, instanceID: file.instanceID)
            switch LicencePolicy.decision(reply, file: file, now: now()) {
            case .keep:
                apply(file)
            case .forget:
                try? FileManager.default.removeItem(at: fileURL)
                apply(nil)
            case .update(let updated):
                try? save(updated)
                apply(updated)
            }
        } catch {
            apply(file)
        }
    }

    private func apply(_ file: LicenceFile?) {
        let active = file.map { LicencePolicy.isActive($0, now: now()) } ?? false
        isActive = active
        expiresAt = file?.expiresAt
        access.setLicence(active: active)
    }

    private func load() -> LicenceFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LicenceFile.self, from: data)
    }

    private func save(_ file: LicenceFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 0600 from the start. The key is a secret the rest of the Mac should not read.
        guard FileManager.default.createFile(atPath: fileURL.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif
