import AppKit
import Foundation

/// Checks GitHub Releases for a newer tag and installs it.
///
/// Releases are signed with the developer's Developer ID and notarized by Apple.
/// Before anything is swapped in, the downloaded app is verified with
/// `codesign` and `spctl`, and its Team ID is compared to the running app's —
/// so a tampered or re-signed download is refused even if the download itself
/// was intercepted.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case available(version: String, notes: String)
        case downloading(Double)
        case installing
        case upToDate
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    /// Where release metadata comes from. Overridable so a fork only has to
    /// change `Pref.updateFeed` (or the Info.plist) rather than the code.
    private var feedURL: URL {
        if let custom = Pref.d.string(forKey: Pref.updateFeed), let url = URL(string: custom), !custom.isEmpty {
            return url
        }
        let repo = Bundle.main.object(forInfoDictionaryKey: "AtaRepository") as? String ?? "mcpeixoto/Ata"
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    var releasesPage: URL {
        let repo = Bundle.main.object(forInfoDictionaryKey: "AtaRepository") as? String ?? "mcpeixoto/Ata"
        return URL(string: "https://github.com/\(repo)/releases")!
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var downloader: Downloader?
    private var pendingAsset: URL?

    // MARK: - Checking

    /// Called at launch and once a day after that, when the user has automatic
    /// checks on. Silent: it only moves `state` to `.available`.
    func checkInBackground() {
        guard Pref.d.bool(forKey: Pref.autoUpdate) else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 23 * 3600 { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard state != .checking, !isDownloading else { return }
        state = .checking
        Task {
            do {
                let release = try await fetchLatest()
                lastCheck = Date()
                guard let release else {
                    state = silent ? .idle : .upToDate
                    return
                }
                if Self.isNewer(release.version, than: Self.currentVersion), release.asset != nil {
                    pendingAsset = release.asset
                    state = .available(version: release.version, notes: release.notes)
                    if silent { Notifier.shared.updateAvailable(version: release.version) }
                } else {
                    pendingAsset = nil
                    state = silent ? .idle : .upToDate
                }
            } catch {
                state = silent ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    private var isDownloading: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    private struct Release {
        let version: String
        let notes: String
        let asset: URL?
    }

    private func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: feedURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Ata/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil } // no releases published yet
        guard (200..<300).contains(code) else {
            throw NSError(domain: "Ata.Updater", code: code, userInfo: [
                NSLocalizedDescriptionKey: L("Could not reach the update server (HTTP %d).", code),
            ])
        }
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        if payload.draft == true || payload.prerelease == true { return nil }
        let asset = payload.assets
            .first { $0.name.lowercased().hasSuffix(".zip") }?
            .browser_download_url
        return Release(version: Self.normalize(payload.tag_name),
                       notes: payload.body ?? "",
                       asset: asset.flatMap(URL.init(string:)))
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    // MARK: - Versions

    nonisolated static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric compare of dot-separated versions, so 2.10 > 2.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Installing

    func installUpdate() {
        guard let asset = pendingAsset, !isDownloading else { return }
        state = .downloading(0)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ata-update-\(UUID().uuidString).zip")

        let d = Downloader(dest: dest) { [weak self] p in
            Task { @MainActor in
                guard let self, self.isDownloading else { return }
                self.state = .downloading(p)
            }
        } completion: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed(error.localizedDescription)
                    try? FileManager.default.removeItem(at: dest)
                    return
                }
                await self.swapIn(zip: dest)
            }
        }
        downloader = d
        d.start(asset)
    }

    private func swapIn(zip: URL) async {
        state = .installing
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ata-update-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: zip)
            try? FileManager.default.removeItem(at: work)
        }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", ["-xk", zip.path, work.path])

            guard let app = try FileManager.default
                .contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "Ata.Updater", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("The download did not contain an app."),
                ])
            }

            try await verify(app)

            // Replace the running bundle, then relaunch from the new copy.
            let installed = URL(fileURLWithPath: Bundle.main.bundlePath)
            let backup = installed.deletingLastPathComponent()
                .appendingPathComponent("Ata.app.old-\(UUID().uuidString)")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: installed, to: backup)
            do {
                try FileManager.default.copyItem(at: app, to: installed)
            } catch {
                // Put the working app back before giving up.
                try? FileManager.default.removeItem(at: installed)
                try? FileManager.default.moveItem(at: backup, to: installed)
                throw error
            }
            try? FileManager.default.removeItem(at: backup)

            relaunch(installed)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Refuses anything that is not a notarized build from the same team as the
    /// app that is running.
    private func verify(_ app: URL) async throws {
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        let assessment = try? await output("/usr/sbin/spctl", ["-a", "-vv", "-t", "install", app.path])
        let notarized = (assessment ?? "").contains("accepted")
        guard notarized else {
            throw NSError(domain: "Ata.Updater", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L("The downloaded update is not notarized by Apple. Nothing was installed."),
            ])
        }

        let newTeam = try await teamID(of: app)
        let ownTeam = try await teamID(of: URL(fileURLWithPath: Bundle.main.bundlePath))
        guard let newTeam, let ownTeam, newTeam == ownTeam else {
            throw NSError(domain: "Ata.Updater", code: 3, userInfo: [
                NSLocalizedDescriptionKey: L("The downloaded update is signed by a different developer. Nothing was installed."),
            ])
        }
    }

    private func teamID(of app: URL) async throws -> String? {
        let text = try await output("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            return nil
        }
        let value = line.replacingOccurrences(of: "TeamIdentifier=", with: "").trimmingCharacters(in: .whitespaces)
        return value == "not set" ? nil : value
    }

    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(app.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Process helpers

    @discardableResult
    private func run(_ path: String, _ args: [String]) async throws -> String {
        try await output(path, args)
    }

    private func output(_ path: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            // Read before waiting so a chatty tool cannot fill the pipe and deadlock.
            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            if p.terminationStatus == 0 {
                cont.resume(returning: text)
            } else {
                let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
                cont.resume(throwing: NSError(domain: "Ata.Updater", code: Int(p.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: tail.isEmpty
                        ? L("%@ failed with code %d", (path as NSString).lastPathComponent, p.terminationStatus)
                        : tail,
                ]))
            }
        }
    }

    func dismiss() {
        state = .idle
    }

    // MARK: - Command line

    /// `Ata --update-now`: check, and install if there is something newer,
    /// without any UI. Exits 0 when already up to date; on success the app is
    /// replaced and relaunched as usual. Handy for scripting, and the way the
    /// updater is tested end to end.
    static var commandLineRequested: Bool { CommandLine.arguments.contains("--update-now") }

    func runFromCommandLine() {
        func say(_ s: String) { print("Ata updater: \(s)"); fflush(stdout) }
        say("running \(Self.currentVersion), checking \(feedURL.absoluteString)")
        Pref.d.set(true, forKey: Pref.autoUpdate)
        check()
        Task { @MainActor in
            var reported = ""
            while true {
                let line: String
                switch state {
                case .idle, .checking: line = "checking…"
                case .upToDate:
                    say("already up to date")
                    exit(0)
                case .available(let version, _):
                    line = "found \(version), installing"
                    installUpdate()
                case .downloading(let p): line = "downloading \(Int(p * 100) / 10 * 10)%"
                case .installing: line = "verifying and installing"
                case .failed(let message):
                    say("failed: \(message)")
                    exit(1)
                }
                if line != reported { say(line); reported = line }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
