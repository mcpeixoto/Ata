import Foundation

/// One anonymous ping a day: how many installs there are, on which version and
/// OS, how much they record, and the aggregate funnel counters below. The whole
/// payload is `Payload` — nothing about a meeting, a person or a file, and no
/// timestamp finer than the day. The country is read by the server from the
/// connection; the address itself is never stored. Off with one switch in
/// Settings, which also forgets the id and anything still waiting to be sent.
///
/// Counts, not an event stream. `onboardingStep` is the furthest step reached
/// since the last ping, not how many times a step was seen.
enum Funnel {
    enum Trigger: String, CaseIterable {
        case onboarding
        case eightyPercent
        case firstTranscript
        case limit
        case settings
        case feature
        case recordHome
    }

    case onboardingStep(Int)
    case paywallShown(Trigger)
    case trialStarted
    case purchased(Plan)
    case limitHit
    case featureLocked(ProFeature)
    case firstTranscript

    /// The part after `funnel.` in UserDefaults, and the key in the ping.
    var name: String {
        switch self {
        case .onboardingStep: return "onboardingStep"
        case .paywallShown(let trigger): return "paywallShown.\(trigger.rawValue)"
        case .trialStarted: return "trialStarted"
        case .purchased(let plan): return "purchased.\(plan.rawValue)"
        case .limitHit: return "limitHit"
        case .featureLocked(let feature): return "featureLocked.\(feature.rawValue)"
        case .firstTranscript: return "firstTranscript"
        }
    }

    var storageKey: String { "funnel.\(name)" }

    /// Everything this build will put in a ping. A `funnel.*` value written by
    /// a newer or older build that is not in here is left on disk and not sent.
    static let knownNames: Set<String> = {
        var names: Set<String> = ["onboardingStep", "trialStarted", "limitHit", "firstTranscript"]
        for trigger in Trigger.allCases { names.insert("paywallShown.\(trigger.rawValue)") }
        for plan in Plan.allCases { names.insert("purchased.\(plan.rawValue)") }
        for feature in ProFeature.allCases { names.insert("featureLocked.\(feature.rawValue)") }
        return names
    }()

    /// Counts only while sharing is on. The onboarding step keeps the highest
    /// value seen; every other case adds one.
    static func count(_ event: Funnel, defaults: UserDefaults = Pref.d) {
        guard Metrics.isOn(defaults) else { return }
        let key = event.storageKey
        switch event {
        case .onboardingStep(let step):
            defaults.set(max(defaults.integer(forKey: key), step), forKey: key)
        default:
            defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        }
    }

    /// Known counters that are actually stored. Nil when there is nothing to
    /// send, so an old server that ignores unknown JSON keys also sees no key.
    static func snapshot(_ defaults: UserDefaults) -> [String: Int]? {
        var counts: [String: Int] = [:]
        for name in knownNames {
            let key = "funnel.\(name)"
            guard defaults.object(forKey: key) != nil else { continue }
            let value = defaults.integer(forKey: key)
            // Step 0 is the first step. Every other counter starts at 1.
            if name != "onboardingStep", value <= 0 { continue }
            counts[name] = value
        }
        return counts.isEmpty ? nil : counts
    }
}

enum Metrics {
    struct Payload: Codable, Equatable {
        let id: String
        let platform: String
        let version: String
        let build: String
        let os: String
        let locale: String
        let meetings: Int
        let minutes: Int
        /// Absent when there is nothing to report. Keys are `Funnel.knownNames` only.
        let funnel: [String: Int]?
        /// Apple Search Ads campaign, once Track 11 has stored it. Absent until then.
        let campaign: String?
    }

    /// What a ping covers, so only that much is taken off the counters once it
    /// lands: a recording that stops while it is in flight is kept for tomorrow.
    struct Due: Equatable {
        let payload: Payload
        let seconds: Double
    }

    static let maxMeetings = 10_000

    static func isOn(_ defaults: UserDefaults = Pref.d) -> Bool {
        defaults.object(forKey: Pref.shareUsage) as? Bool ?? true
    }

    /// Called when a recording stops on this device. Imported and synced
    /// meetings never pass through here, so nothing is counted twice.
    static func recorded(seconds: TimeInterval, defaults: UserDefaults = Pref.d) {
        guard isOn(defaults), seconds > 0, seconds.isFinite else { return }
        defaults.set(defaults.integer(forKey: Pref.metricsPendingMeetings) + 1, forKey: Pref.metricsPendingMeetings)
        defaults.set(defaults.double(forKey: Pref.metricsPendingSeconds) + seconds, forKey: Pref.metricsPendingSeconds)
    }

    /// Today's ping, or nil: switched off, onboarding not finished (the user
    /// has not been told yet), or already sent today.
    ///
    /// Someone who quits during onboarding never sends anything, including the
    /// funnel step they reached. That drop-off is read from App Store Connect
    /// (installs against sessions). There is no ping before they have been told.
    static func due(now: Date = Date(), defaults: UserDefaults = Pref.d) -> Due? {
        guard isOn(defaults) else {
            forget(defaults)
            return nil
        }
        guard defaults.bool(forKey: Pref.onboarded) else { return nil }
        let today = day(now)
        guard defaults.string(forKey: Pref.metricsLastSent) != today else { return nil }
        let id: String
        if let saved = defaults.string(forKey: Pref.metricsID) {
            id = saved
        } else {
            // Its own id, never `Device.id`: that one is written into every
            // meeting.json, and would tie these numbers to meeting files.
            id = UUID().uuidString
            defaults.set(id, forKey: Pref.metricsID)
        }
        let seconds = max(0, defaults.double(forKey: Pref.metricsPendingSeconds))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let payload = Payload(
            id: id,
            platform: platform,
            version: info("CFBundleShortVersionString"),
            build: info("CFBundleVersion"),
            os: "\(os.majorVersion).\(os.minorVersion)",
            locale: locale(),
            meetings: min(maxMeetings, max(0, defaults.integer(forKey: Pref.metricsPendingMeetings))),
            minutes: min(maxMeetings, Int((seconds / 60).rounded())),
            funnel: Funnel.snapshot(defaults),
            campaign: campaign(defaults))
        return Due(payload: payload, seconds: seconds)
    }

    /// The server took it: take what it covered off the counters.
    static func sent(_ due: Due, now: Date = Date(), defaults: UserDefaults = Pref.d) {
        defaults.set(day(now), forKey: Pref.metricsLastSent)
        let meetings = defaults.integer(forKey: Pref.metricsPendingMeetings) - due.payload.meetings
        let seconds = defaults.double(forKey: Pref.metricsPendingSeconds) - due.seconds
        defaults.set(max(0, meetings), forKey: Pref.metricsPendingMeetings)
        defaults.set(max(0, seconds), forKey: Pref.metricsPendingSeconds)
        guard let funnel = due.payload.funnel else { return }
        for (name, reported) in funnel {
            let key = "funnel.\(name)"
            // The step is how far they got, not a tally. Taking the sent number
            // off a higher step reached while the ping was in flight would
            // report the difference next time (5 − 2 = 3) instead of step 5.
            if name == "onboardingStep" {
                if defaults.integer(forKey: key) <= reported {
                    defaults.removeObject(forKey: key)
                }
                continue
            }
            let left = defaults.integer(forKey: key) - reported
            if left > 0 {
                defaults.set(left, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func forget(_ defaults: UserDefaults = Pref.d) {
        for key in [Pref.metricsID, Pref.metricsPendingMeetings, Pref.metricsPendingSeconds, Pref.metricsLastSent] {
            defaults.removeObject(forKey: key)
        }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("funnel.") {
            defaults.removeObject(forKey: key)
        }
    }

    private static func campaign(_ defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: Pref.attributionCampaign), !value.isEmpty else { return nil }
        return value
    }

    /// Where pings go. No `AtaMetricsURL` in the Info.plist (a fork, `swift
    /// test`, snapshots) means nothing is sent. A scratch run with
    /// `ATA_MEETINGS_DIR` stays quiet too, unless `ATA_METRICS_URL` says where.
    static func endpoint(env: [String: String] = ProcessInfo.processInfo.environment,
                         plist: String? = Bundle.main.object(forInfoDictionaryKey: "AtaMetricsURL") as? String) -> URL? {
        if let custom = env["ATA_METRICS_URL"], !custom.isEmpty { return URL(string: custom) }
        if env["ATA_MEETINGS_DIR"] != nil { return nil }
        guard let plist, !plist.isEmpty else { return nil }
        return URL(string: plist)
    }

    private static var sending = false

    /// At launch and on the maintenance tick. Silent: a failure is retried on
    /// the next one.
    @MainActor
    static func sendIfDue() {
        guard !sending, let url = endpoint(), let due = due() else { return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Ata/\(due.payload.version)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 15
            req.httpBody = try? JSONEncoder().encode(due.payload)
            guard let (_, response) = try? await URLSession.shared.data(for: req),
                  let code = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(code) else { return }
            sent(due)
        }
    }

    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }

    /// Language and region only, "pt-PT": the full identifier can carry a
    /// calendar, numbering system and more, which say nothing useful.
    static func locale(_ l: Locale = .current) -> String {
        let language = l.language.languageCode?.identifier ?? "und"
        guard let region = l.region?.identifier else { return language }
        return "\(language)-\(region)"
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "0"
    }
}
