import Foundation

/// One anonymous ping a day: how many installs there are, on which version and
/// OS, and how much they record. The whole payload is `Payload` — nothing about
/// a meeting, a person or a file. The country is read by the server from the
/// connection; the address itself is never stored. Off with one switch in
/// Settings, which also forgets the id and anything still waiting to be sent.
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
            minutes: min(maxMeetings, Int((seconds / 60).rounded())))
        return Due(payload: payload, seconds: seconds)
    }

    /// The server took it: take what it covered off the counters.
    static func sent(_ due: Due, now: Date = Date(), defaults: UserDefaults = Pref.d) {
        defaults.set(day(now), forKey: Pref.metricsLastSent)
        let meetings = defaults.integer(forKey: Pref.metricsPendingMeetings) - due.payload.meetings
        let seconds = defaults.double(forKey: Pref.metricsPendingSeconds) - due.seconds
        defaults.set(max(0, meetings), forKey: Pref.metricsPendingMeetings)
        defaults.set(max(0, seconds), forKey: Pref.metricsPendingSeconds)
    }

    static func forget(_ defaults: UserDefaults = Pref.d) {
        for key in [Pref.metricsID, Pref.metricsPendingMeetings, Pref.metricsPendingSeconds, Pref.metricsLastSent] {
            defaults.removeObject(forKey: key)
        }
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
