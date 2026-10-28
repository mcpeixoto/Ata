import Foundation

/// "Keep meetings in iCloud": finding iCloud, copying the library in, moving to
/// it, and watching it for what the other device changes. The Mac's `AppStore`
/// and the iPhone's `PhoneStore` start it and say when the library may move.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var status: CloudLibrary.Status = .checking
    /// The setting: on once the library has been copied and checked.
    @Published private(set) var isOn = false
    /// Copying meetings into iCloud, or waiting to move to them.
    @Published private(set) var copying = false
    @Published private(set) var copied = 0
    @Published private(set) var total = 0
    @Published private(set) var problem: String?
    /// The meetings folder on this Mac that was copied into iCloud and kept as it was.
    @Published private(set) var originals: URL?

    var inCloud: Bool { CloudLibrary.isActive }

    private var isIdle: @MainActor () -> Bool = { true }
    private var changed: @MainActor () -> Void = {}
    private var started = false
    private var lookup: CloudLibrary.Lookup?
    private var copyTask: Task<Void, Never>?
    private var stopFlag = StopFlag()
    private var target: LibraryLocation?
    private var passes = 0
    private var retry: Timer?
    private var lastCleanUp = Date.distantPast
    private let watcher = CloudWatcher()

    /// `isIdle`: nothing is recording, transcribing, importing or mixing, so the
    /// library can move. `changed`: the library moved, or the other device changed it.
    func start(isIdle: @escaping @MainActor () -> Bool, changed: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.isIdle = isIdle
        self.changed = changed
        isOn = Pref.d.bool(forKey: Pref.iCloudSync)
        // Development and test folders never touch iCloud.
        guard !Paths.overridden else {
            status = .available
            return
        }
        // Otherwise iCloud is only looked for when Settings is opened.
        if isOn || Pref.d.bool(forKey: Pref.iCloudMigrating) {
            Task { await refresh() }
        }
    }

    /// Looks for iCloud again, then picks up the copy if it is due.
    func refresh() async {
        guard !Paths.overridden else { return }
        let found = await CloudLibrary.lookUp()
        lookup = found
        status = found.status
        updateOriginals()
        if isOn, CloudLibrary.isActive { startWatching() }
        // Every launch while this is on: whatever an interruption left, and anything
        // recorded here while iCloud was away. With nothing new it only compares dates.
        if isOn || Pref.d.bool(forKey: Pref.iCloudMigrating), let documents = found.documents {
            copyIn(to: documents)
        }
        updateSettingsSync()
    }

    /// iCloud wasn't found, or not looked for yet: look now, for Settings or for
    /// someone who has just signed in.
    func recheck() {
        guard started, !Paths.overridden, status != .available else { return }
        Task { await refresh() }
    }

    // MARK: Turning it on and off

    func turnOn() {
        guard !Paths.overridden else {
            problem = L("iCloud stays off while Ata uses a development folder.")
            return
        }
        guard status == .available, let documents = lookup?.documents else { return }
        copyIn(to: documents)
    }

    /// Back to this device's folder. What is in iCloud stays there.
    func turnOff() {
        stopFlag.stop()
        copyTask = nil
        retry?.invalidate()
        retry = nil
        passes = 0
        Pref.d.set(false, forKey: Pref.iCloudSync)
        Pref.d.set(false, forKey: Pref.iCloudMigrating)
        isOn = false
        copying = false
        problem = nil
        watcher.stop()
        updateSettingsSync()
        target = CloudLibrary.isActive ? .local : nil
        moveWhenIdle()
        updateOriginals()
    }

    // MARK: Copying

    private func copyIn(to documents: URL) {
        guard copyTask == nil else { return }
        let destination = LibraryLocation.cloud(documents)
        let migration = CloudMigration(source: Paths.localMeetingsDir, destination: destination.meetings,
                                       ledgerURL: CloudLibrary.ledgerURL)
        let voicesFrom = Paths.localVoicesDir
        let flag = StopFlag()
        stopFlag = flag
        // Remembered, so a copy cut short by a quit carries on at the next launch.
        Pref.d.set(true, forKey: Pref.iCloudMigrating)
        copying = true
        problem = nil
        copyTask = Task {
            let outcome = await Task.detached(priority: .utility) { () -> CloudMigration.Outcome in
                var outcome = migration.run(shouldContinue: { !flag.stopped }) { done, total in
                    Task { @MainActor in
                        guard !flag.stopped else { return }
                        CloudSync.shared.copied = done
                        CloudSync.shared.total = total
                    }
                }
                if !outcome.stopped {
                    outcome.failed += migration.copyVoices(from: voicesFrom, to: destination.voices)
                }
                return outcome
            }.value
            // Turned off meanwhile: whatever was copied stays, nothing moves.
            guard flag === stopFlag, !flag.stopped else { return }
            copyTask = nil
            if outcome.failed.isEmpty {
                target = destination
                moveWhenIdle()
            } else {
                copying = false
                problem = L("%d items could not be copied into iCloud. Nothing was moved, and Ata tries again the next time it opens.",
                            outcome.failed.count)
            }
        }
    }

    /// Moves to `target` once nothing is using the library. Into iCloud only when
    /// every meeting here is in iCloud as it is now; anything changed since its
    /// copy gets another pass first.
    private func moveWhenIdle() {
        retry?.invalidate()
        retry = nil
        guard let target else { return }
        let moves = CloudLibrary.location != target
        guard !moves || isIdle() else {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
                MainActor.assumeIsolated { CloudSync.shared.moveWhenIdle() }
            }
            return
        }
        if target.inCloud {
            let migration = CloudMigration(source: Paths.localMeetingsDir, destination: target.meetings,
                                           ledgerURL: CloudLibrary.ledgerURL)
            // Something keeps changing: move anyway after a few passes. The originals
            // stay, so nothing is lost, and the next launch copies the rest.
            if !migration.isComplete, passes < 3, let documents = lookup?.documents {
                passes += 1
                self.target = nil
                copyIn(to: documents)
                return
            }
            passes = 0
            Pref.d.set(true, forKey: Pref.iCloudSync)
            Pref.d.set(false, forKey: Pref.iCloudMigrating)
            isOn = true
            copying = false
        }
        self.target = nil
        if moves {
            CloudLibrary.use(target)
            NSLog("Ata: the library is now in \(target.inCloud ? "iCloud" : "this device's folder"): \(target.meetings.path)")
        }
        if target.inCloud { startWatching() }
        updateOriginals()
        updateSettingsSync()
        changed()
        cleanUpOriginals()
    }

    private func updateSettingsSync() {
        #if os(macOS)
        // The key-value store needs the iCloud entitlement, which a Developer ID build lacks.
        let can = lookup?.entitled == true
        #else
        let can = true
        #endif
        SettingsSync.shared.update(on: isOn && CloudLibrary.isActive && can)
    }

    // MARK: Watching

    private func startWatching() {
        let location = CloudLibrary.location
        watcher.start(meetings: location.meetings, voices: location.voices,
                      useQuery: lookup?.entitled == true) {
            let sync = CloudSync.shared
            sync.changed()
            sync.cleanUpOriginals()
        }
    }

    // MARK: Originals

    private func updateOriginals() {
        #if os(macOS)
        let local = Paths.localMeetingsDir
        let hasMeetings = !((try? FileManager.default.contentsOfDirectory(
            at: local, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).isEmpty
        originals = isOn && CloudLibrary.isActive && hasMeetings ? local : nil
        #else
        originals = nil
        #endif
    }

    /// On iPhone the originals go once their copy is checked, unchanged and
    /// uploaded: space is short there. On the Mac they stay until you remove them.
    private func cleanUpOriginals() {
        #if os(iOS)
        guard isOn, CloudLibrary.isActive, !copying, Date().timeIntervalSince(lastCleanUp) > 60 else { return }
        lastCleanUp = Date()
        let migration = CloudMigration(source: Paths.localMeetingsDir, destination: CloudLibrary.location.meetings,
                                       ledgerURL: CloudLibrary.ledgerURL)
        Task.detached(priority: .utility) {
            for name in migration.removableOriginals() {
                do {
                    try FileManager.default.removeItem(at: migration.source.appendingPathComponent(name, isDirectory: true))
                } catch {
                    NSLog("Ata: kept \(name) on this iPhone: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }
}

/// Notices what the other device changes in the library, and fetches the small
/// files the list and the meeting window read before anyone opens them.
///
/// With the iCloud entitlement that is an `NSMetadataQuery` over the container's
/// Documents. A Developer ID Mac build has no entitlement, so it looks at the
/// folder every few seconds instead.
@MainActor
final class CloudWatcher {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?
    private var debounce: Timer?
    private var polling = false
    private var signatures: [String: String] = [:]
    private var lastResults: Int?
    private var meetings: URL?
    private var voices: URL?
    private var onChange: (@MainActor () -> Void)?

    func start(meetings: URL, voices: URL, useQuery: Bool, onChange: @escaping @MainActor () -> Void) {
        stop()
        self.meetings = meetings
        self.voices = voices
        self.onChange = onChange
        if useQuery { startQuery() } else { startPolling() }
    }

    func stop() {
        query?.stop()
        query = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        poll?.invalidate()
        poll = nil
        debounce?.invalidate()
        debounce = nil
        signatures = [:]
        lastResults = nil
        meetings = nil
        voices = nil
        onChange = nil
    }

    // MARK: Metadata query

    private func startQuery() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        q.notificationBatchingInterval = 1
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.queryChanged() }
            })
        }
        query = q
        _ = q.start()
    }

    private func queryChanged() {
        guard let q = query else { return }
        q.disableUpdates()
        var conflicted: [URL] = []
        var hasher = Hasher()
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            if (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) == true {
                conflicted.append(url)
            }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let changedAt = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            hasher.combine(url.path)
            hasher.combine(status)
            hasher.combine(changedAt)
            if CloudFiles.wantsEagerDownload(url), status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
        q.enableUpdates()
        if !conflicted.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                for url in conflicted { Conflicts.resolve(url) }
            }
        }
        // Upload progress alone updates the query too; only a real change reloads.
        let signature = hasher.finalize()
        guard signature != lastResults else { return }
        lastResults = signature
        scheduleChange()
    }

    private func scheduleChange() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    // MARK: Polling the folder

    private func startPolling() {
        pollNow()
        poll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNow() }
        }
    }

    private func pollNow() {
        guard !polling, let meetings, let voices else { return }
        polling = true
        let previous = signatures
        Task {
            let scanned = await Task.detached(priority: .utility) {
                CloudWatcher.scan(meetings: meetings, voices: voices, previous: previous)
            }.value
            polling = false
            // Stopped, or moved to another folder, meanwhile.
            guard self.meetings == meetings else { return }
            let first = signatures.isEmpty
            signatures = scanned
            if !first, scanned != previous { onChange?() }
        }
    }

    /// One line per folder: its files, sizes, dates and whether each is downloaded.
    /// For folders that changed, asks for the small files and settles conflicts.
    nonisolated static func scan(meetings: URL, voices: URL, previous: [String: String]) -> [String: String] {
        let fm = FileManager.default
        var folders = ((try? fm.contentsOfDirectory(at: meetings, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])) ?? [])
            .filter { CloudLibrary.isDirectory($0) }
        folders.append(voices)
        var out: [String: String] = [:]
        for folder in folders {
            let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])) ?? [])
                .filter { !CloudLibrary.isDirectory($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let line = files.map { file -> String in
                let attributes = try? fm.attributesOfItem(atPath: file.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return "\(file.lastPathComponent):\(size):\(date):\(CloudFiles.isDataless(file))"
            }.joined(separator: "|")
            let key = folder.path
            out[key] = line
            guard previous[key] != line else { continue }
            for file in files where CloudFiles.wantsEagerDownload(file) || file.lastPathComponent.hasSuffix(".icloud") {
                let name = file.lastPathComponent
                // ".notes.md.icloud" stands for notes.md.
                let real = name.hasPrefix(".") && name.hasSuffix(".icloud")
                    ? folder.appendingPathComponent(String(name.dropFirst().dropLast(7))) : file
                guard CloudFiles.wantsEagerDownload(real) else { continue }
                CloudFiles.requestDownload(real)
                if CloudFiles.state(of: real) == .local { Conflicts.resolve(real) }
            }
        }
        return out
    }
}
