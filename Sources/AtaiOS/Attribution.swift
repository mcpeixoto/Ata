import AdServices
import Foundation

/// Asks Apple once, after onboarding, and only while usage stats are on.
/// Screenshots and UI tests launch with `-AtaSnapshots` and never call out.
enum AttributionCapture {
    @MainActor private static var inFlight = false

    @MainActor
    static func startIfNeeded() {
        guard !Snapshots.rendering, !inFlight, Attribution.shouldFetch() else { return }
        inFlight = true
        Task {
            await Attribution.capture(client: LiveAdServices())
            inFlight = false
        }
    }
}

/// `AAAttribution.attributionToken()` can block, so it runs off the main thread.
/// A 404 is Apple's "not ready yet": wait and try twice more in this session.
private struct LiveAdServices: AdServicesClient {
    func attributionToken() async throws -> String {
        try await Task.detached(priority: .utility) {
            try AAAttribution.attributionToken()
        }.value
    }

    func attributionData(token: String) async throws -> Data {
        var last: Error = URLError(.badServerResponse)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 5_000_000_000) }
            do {
                return try await post(token)
            } catch is NotReady {
                last = NotReady()
            }
        }
        throw last
    }

    private func post(_ token: String) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw NotReady() }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// POST the token. See `Attribution` for which fields of the record are kept.
    static let endpoint = URL(string: "https://api-adservices.apple.com/api/v1/")!

    private struct NotReady: Error {}
}
