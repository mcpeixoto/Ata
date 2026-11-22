import Foundation

/// Apple Search Ads attribution for the daily ping. The AdServices call itself
/// lives behind `AdServicesClient` (the iPhone app supplies the real one) so a
/// test can hand back fixture JSON and never open a connection.
///
/// What Apple documents for `AAAttribution.attributionToken()`: the token is
/// posted as `text/plain` to `https://api-adservices.apple.com/api/v1/`. A 200
/// body is JSON. `attribution` is a bool. When it is true the record also
/// carries `campaignId` (an integer) plus org, ad group, keyword, ad, dates
/// and country; this keeps only `campaignId`. When it is false the install
/// was not from a campaign. 404 means the token is not ready yet.
protocol AdServicesClient: Sendable {
    func attributionToken() async throws -> String
    func attributionData(token: String) async throws -> Data
}

enum Attribution {
    enum Result: Equatable {
        /// A campaign id, or `organic` when Apple said the install was not attributed.
        case campaign(String)
        /// No record yet: try again later. Nothing is stored.
        case retry
    }

    static let organic = "organic"

    /// Three failures, then stop. A device that is offline on the first launches
    /// still gets a chance; one that will never get a record does not ask forever.
    private static let maxAttempts = 3
    private static let attemptsKey = "attributionAttempts"

    static func parse(_ data: Data) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .retry }
        guard let flag = json["attribution"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
            return .retry
        }
        if !flag.boolValue { return .campaign(organic) }
        guard let id = integerString(json["campaignId"]) else { return .retry }
        return .campaign(id)
    }

    static func fetch(client: any AdServicesClient) async -> Result {
        do {
            let token = try await client.attributionToken()
            let data = try await client.attributionData(token: token)
            return parse(data)
        } catch {
            return .retry
        }
    }

    /// After onboarding, while sharing is on, and not already answered.
    static func shouldFetch(defaults: UserDefaults = Pref.d) -> Bool {
        guard Metrics.isOn(defaults), defaults.bool(forKey: Pref.onboarded) else { return false }
        if let existing = defaults.string(forKey: Pref.attributionCampaign), !existing.isEmpty { return false }
        return defaults.integer(forKey: attemptsKey) < maxAttempts
    }

    static func apply(_ result: Result, defaults: UserDefaults = Pref.d) {
        guard case .campaign(let id) = result, !id.isEmpty else { return }
        if let existing = defaults.string(forKey: Pref.attributionCampaign), !existing.isEmpty { return }
        defaults.set(id, forKey: Pref.attributionCampaign)
    }

    /// One attempt. A stored campaign or `organic` means it will not ask again.
    static func capture(defaults: UserDefaults = Pref.d, client: any AdServicesClient) async {
        guard shouldFetch(defaults: defaults) else { return }
        defaults.set(defaults.integer(forKey: attemptsKey) + 1, forKey: attemptsKey)
        apply(await fetch(client: client), defaults: defaults)
    }

    /// Apple's `campaignId` is a JSON integer. A bool or a fraction is not one.
    private static func integerString(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double <= Double(Int64.max), double >= Double(Int64.min) else { return nil }
        return String(number.int64Value)
    }
}
