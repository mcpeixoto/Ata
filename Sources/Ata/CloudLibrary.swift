import Foundation

// Meetings and voices in iCloud Drive, shared by the Mac and the iPhone.
//
// The folder format is the same as on one device: `Documents/Meetings/<meeting>/`
// and `Documents/Voices/<id>.json` inside Ata's iCloud container. The library
// moves there only after every meeting has been copied and checked, and the
// originals are never deleted on the way.

// MARK: - Where the library lives

/// Where meetings and voices are kept: on this device, or in Ata's iCloud container.
struct LibraryLocation: Equatable, Sendable {
    var meetings: URL
    var voices: URL
    var inCloud: Bool

    /// This device's own folders, or the development ones `ATA_MEETINGS_DIR` and
    /// `ATA_SUPPORT_DIR` point at.
    static var local: LibraryLocation {
        LibraryLocation(meetings: Paths.localMeetingsDir, voices: Paths.localVoicesDir, inCloud: false)
    }

    /// `Meetings` and `Voices` in the container's `Documents` folder.
    static func cloud(_ documents: URL) -> LibraryLocation {
        LibraryLocation(meetings: documents.appendingPathComponent("Meetings", isDirectory: true),
                        voices: documents.appendingPathComponent("Voices", isDirectory: true),
                        inCloud: true)
    }

    /// A development or test folder always wins; otherwise iCloud when the setting
    /// is on and the container is there, and this device when it isn't.
    static func resolve(overridden: Bool, syncOn: Bool, cloudDocuments: URL?,
                        local: LibraryLocation) -> LibraryLocation {
        guard !overridden, syncOn, let cloudDocuments else { return local }
        return cloud(cloudDocuments)
    }
}

/// Ata's iCloud container: finding it, and which library is in use.
enum CloudLibrary {
    static let containerID = "iCloud.ai.interactive.ata"
    /// The container's folder in `~/Library/Mobile Documents` on a Mac.
    static let containerFolderName = "iCloud~ai~interactive~ata"

    /// Which meetings are already copied into iCloud, so a copy cut short picks up
    /// where it stopped and a meeting deleted in iCloud isn't copied back.
    static var ledgerURL: URL { Paths.supportDir.appendingPathComponent("icloud-copy.json") }

    private static let box = LocationBox()

    /// The library in use. Chosen at launch from the setting, and changed only
    /// through `use(_:)`, while nothing is recording, transcribing or importing.
    static var location: LibraryLocation { box.get() }

    /// Meetings and voices are in iCloud now.
    static var isActive: Bool { location.inCloud }

    static func use(_ location: LibraryLocation) { box.set(location) }

    /// The library as the setting and the disk say at launch. Never asks iCloud,
    /// so it is safe on the main thread before anything else has run.
    static func launchLocation() -> LibraryLocation {
        LibraryLocation.resolve(overridden: Paths.overridden,
                                syncOn: UserDefaults.standard.bool(forKey: Pref.iCloudSync),
                                cloudDocuments: knownDocuments(), local: .local)
    }

    /// The container's Documents folder as last found, while it is still on disk.
    static func knownDocuments() -> URL? {
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: Pref.iCloudDocuments), !saved.isEmpty {
            candidates.append(URL(fileURLWithPath: saved, isDirectory: true))
        }
        #if os(macOS)
        candidates.append(macDocuments)
        #endif
        return candidates.first { isDirectory($0) && isReal($0) }
    }

    /// iCloud is signed in with iCloud Drive on, and `documents` is in it rather
    /// than a plain folder at the same path. Signing out or turning iCloud Drive
    /// off can leave the path behind, or let something make it again, and a
    /// library kept there would never reach iCloud. Quick enough for the main thread.
    static func isReal(_ documents: URL) -> Bool {
        let fm = FileManager.default
        guard fm.ubiquityIdentityToken != nil else { return false }
        #if os(macOS)
        return fm.isUbiquitousItem(at: documents)
        #else
        return true
        #endif
    }

    /// Makes `folder`, and what is missing above it, but never the container
    /// itself: inside the library's iCloud container only below a `Documents`
    /// folder that is still there. Making the folders above it would leave a plain
    /// local folder where iCloud was, and the library would carry on there unseen.
    static func createFolder(_ folder: URL, location: LibraryLocation = CloudLibrary.location) throws {
        let fm = FileManager.default
        if isDirectory(folder) { return }
        if location.inCloud {
            let documents = location.meetings.deletingLastPathComponent().standardizedFileURL.path
            let path = folder.standardizedFileURL.path
            if path == documents || path.hasPrefix(documents + "/") {
                guard isDirectory(URL(fileURLWithPath: documents, isDirectory: true)) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: documents])
                }
            }
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    #if os(macOS)
    /// Where iCloud Drive keeps the container on a Mac. A Developer ID build has no
    /// iCloud entitlement, so it reads and writes this folder directly; iCloud Drive
    /// creates it once Ata on an iPhone has used the container.
    static var macDocuments: URL {
        Paths.home.appendingPathComponent("Library/Mobile Documents/\(containerFolderName)/Documents",
                                          isDirectory: true)
    }
    #endif

    enum Status: Equatable, Sendable {
        case checking
        case available
        /// Not signed in to iCloud, or iCloud Drive is off.
        case signedOut
        /// A Mac with iCloud Drive where Ata's container doesn't exist yet: Ata on
        /// an iPhone has to turn iCloud on first.
        case notOnThisMac
    }

    struct Lookup: Equatable, Sendable {
        var documents: URL?
        var status: Status
        /// The app has the iCloud entitlement: the metadata query and the key-value
        /// store work. Without it (a Developer ID Mac build) only the folder does.
        var entitled: Bool
    }

    /// Asks iCloud for the container. That can take a while the first time, so it
    /// never runs on the main thread.
    static func lookUp() async -> Lookup {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: lookUpNow())
            }
        }
    }

    private static func lookUpNow() -> Lookup {
        let fm = FileManager.default
        if let container = fm.url(forUbiquityContainerIdentifier: containerID) {
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
            UserDefaults.standard.set(documents.path, forKey: Pref.iCloudDocuments)
            return Lookup(documents: documents, status: .available, entitled: true)
        }
        #if os(macOS)
        if isDirectory(macDocuments), isReal(macDocuments) {
            UserDefaults.standard.set(macDocuments.path, forKey: Pref.iCloudDocuments)
            return Lookup(documents: macDocuments, status: .available, entitled: false)
        }
        // Signed out, or iCloud Drive off, can leave the folder behind.
        let drive = Paths.home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
        let signedIn = fm.ubiquityIdentityToken != nil && isDirectory(drive)
        return Lookup(documents: nil, status: signedIn ? .notOnThisMac : .signedOut, entitled: false)
        #else
        return Lookup(documents: nil, status: .signedOut, entitled: false)
        #endif
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// The location, read from any thread.
private final class LocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LibraryLocation?

    func get() -> LibraryLocation {
        lock.lock()
        defer { lock.unlock() }
        if let value { return value }
        let launched = CloudLibrary.launchLocation()
        value = launched
        return launched
    }

    func set(_ location: LibraryLocation) {
        lock.lock()
        value = location
        lock.unlock()
    }
}

// MARK: - Files that may not be downloaded yet

enum CloudFiles {
    enum State: Equatable {
        case local
        /// In iCloud and not on this device yet.
        case inCloud
        case missing
    }

    enum Failure: LocalizedError {
        case notDownloaded
        /// The meeting's transcript is still in iCloud, so it can't be kept in versions/.
        case transcriptNotDownloaded

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return L("The audio hasn't downloaded from iCloud yet. Try again when this device is online.")
            case .transcriptNotDownloaded:
                return L("The earlier transcript hasn't downloaded from iCloud yet, and Ata won't write over it. Try again when this device is online.")
            }
        }
    }

    /// On iPhone a file iCloud hasn't downloaded is a hidden `.<name>.icloud` beside
    /// where it will be.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    static func isPlaceholder(_ url: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: url.path) && fm.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// SF_DATALESS from <sys/stat.h>.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// On a Mac a file iCloud hasn't downloaded keeps its name and size with no
    /// data on disk ("dataless"); reading it waits for the download.
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & datalessFlag != 0
    }

    static func state(of url: URL) -> State {
        if FileManager.default.fileExists(atPath: url.path) { return isDataless(url) ? .inCloud : .local }
        return FileManager.default.fileExists(atPath: placeholderURL(for: url).path) ? .inCloud : .missing
    }

    /// None of them waits on iCloud.
    static func areLocal(_ urls: [URL]) -> Bool {
        !urls.contains { state(of: $0) == .inCloud }
    }

    /// `url` when reading it won't wait on iCloud: it is on this device, or not
    /// there at all. A file still in iCloud is asked for and gives nil, so the main
    /// thread never waits for a download; the watcher reloads once it has arrived.
    static func readable(_ url: URL) -> URL? {
        guard CloudLibrary.isActive, state(of: url) == .inCloud else { return url }
        requestDownload(url)
        return nil
    }

    /// What the meeting list and the meeting window read, fetched as soon as it
    /// appears. Audio waits until it is played or transcribed.
    static let eagerNames: Set<String> = ["meeting.json", "transcript.json", "transcript.md", "transcricao.md",
                                          "notes.md", "speakers.json", "waveform.bin"]

    static func wantsEagerDownload(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        // Voices are small and the People tab needs every one of them.
        if parent.lastPathComponent == "Voices" { return true }
        // Earlier transcripts, moved aside, are only opened by hand.
        if url.pathComponents.contains("versions") { return false }
        let name = url.lastPathComponent
        return eagerNames.contains(name) || (name.hasPrefix("notes (") && name.hasSuffix(".md"))
    }

    #if os(macOS)
    private static let inFlight = LockedValue<Set<String>>([])
    #endif

    /// Asks iCloud for the file and returns at once.
    static func requestDownload(_ url: URL) {
        guard state(of: url) == .inCloud else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        #if os(macOS)
        // Without the iCloud entitlement that call may do nothing. Reading the file
        // fetches it; that waits for the download, so off the main thread and once
        // per file at a time. A plain read, never a coordinated one: held for as long
        // as the download takes, offline for good, it would keep a coordinated write
        // to the same file on the main thread waiting with it.
        guard inFlight.withLock({ $0.insert(url.path).inserted }) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                _ = try handle.read(upToCount: 1)
                try handle.close()
            } catch {
                NSLog("Ata: could not fetch \(url.lastPathComponent) from iCloud: \(error.localizedDescription)")
            }
            _ = inFlight.withLock { $0.remove(url.path) }
        }
        #endif
    }

    /// Fetches every file that is still in iCloud and waits for them, up to
    /// `timeout`. True when all of them are on this device.
    static func download(_ urls: [URL], timeout: TimeInterval = 15 * 60) async -> Bool {
        let waiting = urls.filter { state(of: $0) == .inCloud }
        guard !waiting.isEmpty else { return true }
        for url in waiting { requestDownload(url) }
        let deadline = Date().addingTimeInterval(timeout)
        while waiting.contains(where: { state(of: $0) == .inCloud }) {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return true
    }

    /// Checked into iCloud, so this device's copy can go. A file that is only a
    /// placeholder here has been uploaded by definition.
    static func isUploaded(_ url: URL) -> Bool {
        if isPlaceholder(url) || isDataless(url) { return true }
        return (try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == true
    }
}

/// A value shared between threads behind a lock.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Coordinated writes

/// Writes that iCloud sees whole. With the library in iCloud every write of the
/// files both devices read goes through `NSFileCoordinator`; on one device it is
/// the plain atomic write it always was.
enum Coordinated {
    static func write(_ data: Data, to url: URL) throws {
        guard CloudLibrary.isActive else {
            try data.write(to: url, options: .atomic)
            return
        }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    static func remove(_ url: URL) throws {
        guard CloudLibrary.isActive else {
            try FileManager.default.removeItem(at: url)
            return
        }
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                removeError = error
            }
        }
        if let removeError { throw removeError }
        if let coordinationError { throw coordinationError }
    }

    /// Moves `url` to the Trash, so the other device sees it go as one change.
    static func trash(_ url: URL) throws {
        guard CloudLibrary.isActive else {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        }
        var coordinationError: NSError?
        var trashError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting,
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            } catch {
                trashError = error
            }
        }
        if let trashError { throw trashError }
        if let coordinationError { throw coordinationError }
    }

    /// Moves `source` to `destination`, which must not exist yet.
    static func move(_ source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: source, options: .forMoving,
                                                         writingItemAt: destination, options: .forReplacing,
                                                         error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
            } catch {
                moveError = error
            }
        }
        if let moveError { throw moveError }
        if let coordinationError { throw coordinationError }
    }
}

// MARK: - Conflicts

/// Two devices changed the same file before either saw the other's change.
enum Conflicts {
    enum Rule: Equatable {
        /// Your notes: the newest stays notes.md and every other version is kept
        /// beside it, so no one's typing is lost.
        case keepBoth
        /// Files Ata writes itself (meeting.json, transcripts, voices): the newest
        /// wins. Claims keep two devices from transcribing the same meeting.
        case newest
    }

    static func rule(for fileName: String) -> Rule {
        fileName == "notes.md" ? .keepBoth : .newest
    }

    struct Plan: Equatable {
        /// The version that keeps the file's name: 0 is the one on this device, then
        /// the conflicting versions in order.
        var winner: Int
        /// Versions saved beside it, by index, with the name each is saved under.
        var keptAside: [Int: String]
    }

    /// What to do with the versions of `fileName`, given when each was last
    /// modified. A tie keeps the version on this device; `taken` are the names
    /// already in the folder.
    static func plan(fileName: String, modified: [Date?], taken: Set<String>) -> Plan {
        guard !modified.isEmpty else { return Plan(winner: 0, keptAside: [:]) }
        var winner = 0
        for i in modified.indices.dropFirst() where (modified[i] ?? .distantPast) > (modified[winner] ?? .distantPast) {
            winner = i
        }
        guard rule(for: fileName) == .keepBoth else { return Plan(winner: winner, keptAside: [:]) }
        var names = taken
        var aside: [Int: String] = [:]
        for i in modified.indices where i != winner {
            var n = 1
            var name = asideName(for: fileName, number: n)
            while names.contains(name) {
                n += 1
                name = asideName(for: fileName, number: n)
            }
            names.insert(name)
            aside[i] = name
        }
        return Plan(winner: winner, keptAside: aside)
    }

    /// "notes (other device).md", then "notes (other device 2).md"…
    static func asideName(for fileName: String, number: Int) -> String {
        let file = URL(fileURLWithPath: fileName)
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        let suffix = number <= 1 ? "(other device)" : "(other device \(number))"
        return ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
    }

    /// The first aside name for `fileName` that nothing in `dir` has, not even a
    /// file still in iCloud.
    static func unusedAsideName(for fileName: String, in dir: URL) -> String {
        var n = 1
        while CloudFiles.state(of: dir.appendingPathComponent(asideName(for: fileName, number: n))) != .missing {
            n += 1
        }
        return asideName(for: fileName, number: n)
    }

    /// Settles the file's conflicting versions by its rule. Nothing is marked
    /// resolved until every version that is kept has been written. Blocks on file
    /// coordination, so never on the main thread.
    static func resolve(_ url: URL) {
        // The metadata query reports a conflict again with every update until it is
        // settled: a second pass on the same file would keep its versions twice.
        guard begin(url) else { return }
        defer { end(url) }
        guard let others = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !others.isEmpty,
              let current = NSFileVersion.currentVersionOfItem(at: url) else { return }
        let versions = [current] + others
        if url.deletingLastPathComponent().lastPathComponent == "Voices",
           VoiceLibrary.voiceID(fileName: url.lastPathComponent) != nil,
           resolveVoice(url, versions: versions, others: others) { return }
        let dir = url.deletingLastPathComponent()
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let decision = Self.plan(fileName: url.lastPathComponent, modified: versions.map(\.modificationDate),
                                 taken: taken)
        do {
            for (i, name) in decision.keptAside.sorted(by: { $0.key < $1.key }) {
                let data = try Data(contentsOf: versions[i].url)
                try Coordinated.write(data, to: dir.appendingPathComponent(name))
            }
            if decision.winner != 0 {
                let winner = versions[decision.winner]
                var coordinationError: NSError?
                var replaceError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                                 error: &coordinationError) { target in
                    do {
                        _ = try winner.replaceItem(at: target, options: [])
                    } catch {
                        replaceError = error
                    }
                }
                if let replaceError { throw replaceError }
                if let coordinationError { throw coordinationError }
            }
            for version in others { version.isResolved = true }
            removeResolvedVersions(of: url)
        } catch {
            NSLog("Ata: left a conflict in \(url.lastPathComponent) unresolved: \(error.localizedDescription)")
        }
    }

    private static let resolving = LockedValue<Set<String>>([])

    /// False while `url` is already being settled.
    static func begin(_ url: URL) -> Bool {
        resolving.withLock { $0.insert(url.standardizedFileURL.path).inserted }
    }

    static func end(_ url: URL) {
        _ = resolving.withLock { $0.remove(url.standardizedFileURL.path) }
    }

    /// Settled versions stay in iCloud, taking space on every device, until they are
    /// removed. Everything worth keeping is in the file or beside it by now.
    private static func removeResolvedVersions(of url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [],
                                                         error: &coordinationError) { target in
            do {
                try NSFileVersion.removeOtherVersionsOfItem(at: target)
            } catch {
                NSLog("Ata: could not remove the old versions of \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if let coordinationError {
            NSLog("Ata: could not remove the old versions of \(url.lastPathComponent): \(coordinationError.localizedDescription)")
        }
    }

    /// A voice changed on both devices: one version, merged, so a name given on one
    /// survives a fingerprint learned on the other (see `VoiceLibrary.merge(versions:)`).
    /// False when a version can't be read as a voice; the newest then wins as usual.
    private static func resolveVoice(_ url: URL, versions: [NSFileVersion], others: [NSFileVersion]) -> Bool {
        let decoder = VoiceLibrary.decoder()
        var read: [VoiceLibrary.Version] = []
        for version in versions {
            guard let data = try? Data(contentsOf: version.url),
                  let voice = try? decoder.decode(Voice.self, from: data) else { return false }
            read.append(VoiceLibrary.Version(voice: voice, modified: version.modificationDate))
        }
        guard let merged = VoiceLibrary.merge(versions: read) else { return false }
        do {
            try Coordinated.write(VoiceLibrary.encoder().encode(merged), to: url)
            for version in others { version.isResolved = true }
            removeResolvedVersions(of: url)
            return true
        } catch {
            NSLog("Ata: could not merge the versions of \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Copying the library into iCloud

/// Copies this device's meetings into iCloud: each folder is copied beside its
/// final place under a hidden name, compared file by file, size and contents, and
/// only then given its name. The originals are never touched. A ledger records
/// what is done, so a copy cut short resumes, a meeting changed since its copy is
/// brought up to date, and one deleted in iCloud is not copied back.
struct CloudMigration: Sendable {
    let source: URL
    let destination: URL
    let ledgerURL: URL
    /// The device copying. A meeting from before Ata 2.6 names no device, which on
    /// one device meant this one; its copy in iCloud says so (see `stampOrigin`).
    var device: DeviceRef = Device.current

    struct Stamp: Codable, Equatable, Sendable {
        var size: Int64
        var modified: Double
    }

    struct Entry: Codable, Equatable, Sendable {
        /// The folder's name in iCloud: its own, unless another device had one by that name.
        var target: String
        /// Every file as it was when it was copied, by path inside the folder.
        var files: [String: Stamp]
        /// Every file in iCloud as this device last wrote it there, so an update can
        /// tell a file the other device has changed since. Absent in ledgers from 2.7.0.
        var copied: [String: Stamp]? = nil
    }

    struct Ledger: Codable, Equatable, Sendable {
        var meetings: [String: Entry] = [:]
        /// Voice files already copied.
        var voices: [String] = []
    }

    struct Outcome: Equatable, Sendable {
        var copied: [String] = []
        var updated: [String] = []
        var failed: [String] = []
        /// Stopped before the end; nothing that was done is undone.
        var stopped = false
    }

    /// One copy at a time, even when a second is asked for before the first stopped.
    static let running = NSLock()

    // MARK: Ledger

    func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    func saveLedger(_ ledger: Ledger) throws {
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
    }

    // MARK: What is left

    /// The meeting folders on this device.
    func sourceFolders() -> [String] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.filter { CloudLibrary.isDirectory($0) }.map(\.lastPathComponent).sorted()
    }

    /// Every file in `folder`, by path inside it, with its size and date. Hidden
    /// files and half-written `.partial` files are left out.
    static func stamps(of folder: URL) -> [String: Stamp] {
        let fm = FileManager.default
        var out: [String: Stamp] = [:]
        for relative in fm.subpaths(atPath: folder.path) ?? [] {
            let parts = relative.split(separator: "/")
            if parts.contains(where: { $0.hasPrefix(".") }) || relative.hasSuffix(".partial") { continue }
            let file = folder.appendingPathComponent(relative)
            guard !CloudLibrary.isDirectory(file), let stamp = stamp(of: file) else { continue }
            out[relative] = stamp
        }
        return out
    }

    /// One file's size and date, or nil when it isn't there (a file iCloud hasn't
    /// downloaded to an iPhone is only its placeholder).
    static func stamp(of file: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Stamp(size: size, modified: modified)
    }

    /// Meeting folders still to copy, or changed since they were.
    func pending() -> [String] {
        pending(in: loadLedger())
    }

    private func pending(in ledger: Ledger) -> [String] {
        sourceFolders().filter { name in
            guard let entry = ledger.meetings[name] else { return true }
            let stamps = Self.stamps(of: source.appendingPathComponent(name, isDirectory: true))
            // Unchanged: done, even if it has since been deleted in iCloud on purpose.
            return stamps != entry.files
        }
    }

    /// Everything on this device is in iCloud, as it is now. Only looks at file
    /// sizes and dates.
    var isComplete: Bool { pending().isEmpty }

    // MARK: Copying

    /// Copies whatever is pending. `shouldContinue` is asked between meetings.
    /// Runs for as long as the copy takes: never on the main thread.
    func run(shouldContinue: () -> Bool = { true },
             progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) -> Outcome {
        Self.running.lock()
        defer { Self.running.unlock() }
        var ledger = loadLedger()
        var outcome = Outcome()
        let todo = pending(in: ledger)
        progress(0, todo.count)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            outcome.failed = todo
            return outcome
        }
        for (i, name) in todo.enumerated() {
            guard shouldContinue() else {
                outcome.stopped = true
                break
            }
            let folder = source.appendingPathComponent(name, isDirectory: true)
            // Taken before copying, so a change made during the copy shows up as one next time.
            let stamps = Self.stamps(of: folder)
            do {
                let entry = ledger.meetings[name]
                let existing = entry.map { destination.appendingPathComponent($0.target, isDirectory: true) }
                if let entry, let existing, CloudLibrary.isDirectory(existing) {
                    let changed = stamps.keys.filter { entry.files[$0] != stamps[$0] }.sorted()
                    let written = try update(changed, from: folder, into: existing, entry: entry)
                    ledger.meetings[name] = Entry(target: entry.target, files: stamps,
                                                  copied: (entry.copied ?? [:]).merging(written) { $1 })
                    outcome.updated.append(name)
                } else {
                    let target = try copyFolder(folder, named: name)
                    ledger.meetings[name] = Entry(target: target, files: stamps,
                                                  copied: Self.stamps(of: destination.appendingPathComponent(target, isDirectory: true)))
                    outcome.copied.append(name)
                }
                try saveLedger(ledger)
            } catch {
                NSLog("Ata: could not copy \(name) into iCloud, the original is untouched: \(error.localizedDescription)")
                outcome.failed.append(name)
            }
            progress(i + 1, todo.count)
        }
        if !outcome.stopped { stampOrigins(in: &ledger) }
        return outcome
    }

    /// Meetings this device copied into iCloud before copies said which device made
    /// them (Ata 2.7.0) say it now: the ledger only lists this device's own.
    private func stampOrigins(in ledger: inout Ledger) {
        var changed = false
        for (name, entry) in ledger.meetings {
            let meta = destination.appendingPathComponent(entry.target, isDirectory: true)
                .appendingPathComponent("meeting.json")
            // A quick look first: most already name their device, and need no coordination.
            guard CloudFiles.state(of: meta) == .local, let data = try? Data(contentsOf: meta),
                  Self.stamped(data, device: device) != nil,
                  (try? Self.stampOrigin(meta, device: device)) == true,
                  let stamp = Self.stamp(of: meta) else { continue }
            // Written by this device, so not a change the other one made.
            var updated = entry
            updated.copied = (entry.copied ?? [:]).merging(["meeting.json": stamp]) { $1 }
            ledger.meetings[name] = updated
            changed = true
        }
        if changed {
            do {
                try saveLedger(ledger)
            } catch {
                NSLog("Ata: could not save the iCloud copy ledger: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Which device made it

    private static let metaEncoder: JSONEncoder = {
        // As `Library.save` writes meeting.json.
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let metaDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// meeting.json as `data` has it, now naming `device` as the one that made it;
    /// nil when it already names a device or isn't a meeting.
    static func stamped(_ data: Data, device: DeviceRef) -> Data? {
        guard var meeting = try? metaDecoder.decode(Meeting.self, from: data), meeting.origin == nil else { return nil }
        meeting.origin = device
        return try? metaEncoder.encode(meeting)
    }

    /// A meeting from before Ata 2.6 names no device: on one device that meant this
    /// one, but in iCloud the other device would take it for its own, and compress or
    /// delete its audio by its own settings. So its copy names the device that copied
    /// it. True when meeting.json was written; one that already names a device, or
    /// can't be read as a meeting, is left as it is.
    static func stampOrigin(_ meta: URL, device: DeviceRef) throws -> Bool {
        var wrote = false
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: meta, options: .forMerging,
                                                         error: &coordinationError) { target in
            guard let data = try? Data(contentsOf: target), let named = Self.stamped(data, device: device) else { return }
            do {
                try named.write(to: target, options: .atomic)
                wrote = true
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinationError { throw coordinationError }
        return wrote
    }

    /// Copies `folder` into the destination and returns the name it has there. A
    /// folder by that name that already holds the same files is this one, copied
    /// by an earlier run that stopped before writing the ledger.
    private func copyFolder(_ folder: URL, named name: String) throws -> String {
        let fm = FileManager.default
        var candidate = name
        var n = 2
        while fm.fileExists(atPath: destination.appendingPathComponent(candidate).path) {
            if Self.verified(destination.appendingPathComponent(candidate, isDirectory: true), against: folder,
                             stampedBy: device) {
                return candidate
            }
            candidate = "\(name) \(n)"
            n += 1
        }
        // Hidden while it's incomplete: no device lists it.
        let partial = destination.appendingPathComponent(".\(candidate).partial", isDirectory: true)
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        do {
            try fm.copyItem(at: folder, to: partial)
            guard Self.verified(partial, against: folder) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
            // Checked as it is here; only then does it say which device made it.
            _ = try Self.stampOrigin(partial.appendingPathComponent("meeting.json"), device: device)
            try Coordinated.move(partial, to: destination.appendingPathComponent(candidate, isDirectory: true))
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return candidate
    }

    /// Brings files that changed since the last copy over, one by one; see
    /// `update(_:to:lastWritten:device:)`. Returns each file in iCloud that now has
    /// this device's version, as it is there.
    private func update(_ files: [String], from folder: URL, into target: URL, entry: Entry) throws -> [String: Stamp] {
        var written: [String: Stamp] = [:]
        for relative in files {
            // As this device left it in iCloud. A 2.7.0 ledger didn't say; a copy keeps
            // the original's date, so the original as it was copied tells the same.
            let lastWritten = [entry.copied?[relative], entry.files[relative]].compactMap { $0 }
            if let placed = try Self.update(folder.appendingPathComponent(relative),
                                            to: target.appendingPathComponent(relative), lastWritten: lastWritten,
                                            device: relative == "meeting.json" ? device : nil) {
                written[relative] = placed
            }
        }
        return written
    }

    /// One file that changed here since it was copied, into iCloud through a checked
    /// hidden copy beside `to`. While `to` is as this device last wrote it there
    /// (`lastWritten`), it is replaced. If the other device has changed it since, or
    /// it hasn't downloaded so nobody can tell, neither version is lost: the newer one
    /// keeps the name and the other is kept beside it under `Conflicts.asideName`.
    /// `device` names who made a meeting.json that doesn't say. Returns `to` as it is
    /// now when this device's version took the name, nil when it was kept beside.
    static func update(_ from: URL, to: URL, lastWritten: [Stamp], device: DeviceRef?) throws -> Stamp? {
        let fm = FileManager.default
        let dir = to.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent(".\(to.lastPathComponent).partial")
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        do {
            try fm.copyItem(at: from, to: partial)
            guard sameContents(partial, from) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
            if let device { _ = try stampOrigin(partial, device: device) }
            let state = CloudFiles.state(of: to)
            let theirs = stamp(of: to)
            if state == .missing {
                try Coordinated.move(partial, to: to)
            } else if let theirs, lastWritten.contains(theirs) {
                try replace(to, with: partial)
            } else if state == .local, sameContents(partial, to) {
                // The same change on both devices.
                try fm.removeItem(at: partial)
            } else {
                let aside = dir.appendingPathComponent(Conflicts.unusedAsideName(for: to.lastPathComponent, in: dir))
                if let theirs, let mine = stamp(of: from), mine.modified > theirs.modified {
                    try Coordinated.move(to, to: aside)
                    try Coordinated.move(partial, to: to)
                } else {
                    try Coordinated.move(partial, to: aside)
                    return nil
                }
            }
            return stamp(of: to)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `from` to `to`, through a checked hidden copy beside `to`.
    static func copyFile(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = to.deletingLastPathComponent().appendingPathComponent(".\(to.lastPathComponent).partial")
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        do {
            try fm.copyItem(at: from, to: partial)
            guard sameContents(partial, from) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
            }
            if fm.fileExists(atPath: to.path) {
                try replace(to, with: partial)
            } else {
                try Coordinated.move(partial, to: to)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// `to` becomes `partial`, in one coordinated step.
    private static func replace(_ to: URL, with partial: URL) throws {
        var coordinationError: NSError?
        var replaceError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: to, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: partial)
            } catch {
                replaceError = error
            }
        }
        if let replaceError { throw replaceError }
        if let coordinationError { throw coordinationError }
    }

    // MARK: Voices

    /// Copies voice files that aren't in iCloud yet. A voice already there is left
    /// as it is: the same id on both sides is the same voice, synced before.
    /// Returns the files that could not be copied.
    func copyVoices(from local: URL, to cloud: URL) -> [String] {
        Self.running.lock()
        defer { Self.running.unlock() }
        let fm = FileManager.default
        var ledger = loadLedger()
        var done = Set(ledger.voices)
        var failed: [String] = []
        let files = ((try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { !CloudLibrary.isDirectory($0) }
        for file in files where !done.contains(file.lastPathComponent) {
            let target = cloud.appendingPathComponent(file.lastPathComponent)
            do {
                if CloudFiles.state(of: target) == .missing {
                    try Self.copyFile(file, to: target)
                }
                done.insert(file.lastPathComponent)
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        ledger.voices = done.sorted()
        do {
            try saveLedger(ledger)
        } catch {
            return files.map(\.lastPathComponent)
        }
        return failed
    }

    // MARK: Originals

    /// Folders on this device whose copy in iCloud is checked, unchanged since and
    /// uploaded: on iPhone, where space is short, those originals can go.
    func removableOriginals(isUploaded: (URL) -> Bool = CloudFiles.isUploaded) -> [String] {
        let ledger = loadLedger()
        return sourceFolders().filter { name in
            guard let entry = ledger.meetings[name] else { return false }
            let target = destination.appendingPathComponent(entry.target, isDirectory: true)
            guard CloudLibrary.isDirectory(target),
                  Self.stamps(of: source.appendingPathComponent(name, isDirectory: true)) == entry.files else { return false }
            return entry.files.keys.allSatisfy { isUploaded(target.appendingPathComponent($0)) }
        }
    }

    // MARK: Checking

    /// Every file in `original` is in `copy`, at the same place, the same size and
    /// with the same bytes.
    static func verified(_ copy: URL, against original: URL) -> Bool {
        guard Library.covers(copy, original) else { return false }
        for relative in stamps(of: original).keys {
            guard sameContents(copy.appendingPathComponent(relative), original.appendingPathComponent(relative)) else {
                return false
            }
        }
        return true
    }

    /// The same, or the same but for its meeting.json naming `device` as the device
    /// that made it, which is how `copyFolder` leaves a meeting from before Ata 2.6.
    static func verified(_ copy: URL, against original: URL, stampedBy device: DeviceRef) -> Bool {
        if verified(copy, against: original) { return true }
        let meta = "meeting.json"
        guard let data = try? Data(contentsOf: original.appendingPathComponent(meta)),
              let expected = stamped(data, device: device),
              (try? Data(contentsOf: copy.appendingPathComponent(meta))) == expected else { return false }
        return stamps(of: original).keys.allSatisfy { relative in
            relative == meta || sameContents(copy.appendingPathComponent(relative), original.appendingPathComponent(relative))
        }
    }

    /// Byte for byte, a megabyte at a time.
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileHandle(forReadingFrom: a), let second = try? FileHandle(forReadingFrom: b) else {
            return false
        }
        defer {
            try? first.close()
            try? second.close()
        }
        while true {
            let x: Data
            let y: Data
            do {
                x = try first.read(upToCount: 1 << 20) ?? Data()
                y = try second.read(upToCount: 1 << 20) ?? Data()
            } catch {
                return false
            }
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }
}

/// Asked between meetings whether a copy should go on.
final class StopFlag: @unchecked Sendable {
    private let state = LockedValue(false)

    var stopped: Bool { state.withLock { $0 } }

    func stop() { state.withLock { $0 = true } }
}

// MARK: - Settings in iCloud

/// The rule for a setting both devices changed: the latest change wins.
enum SettingsMerge {
    enum Value: Equatable, Sendable {
        case string(String)
        case bool(Bool)

        /// Decides a tie the same way on both devices.
        var order: String {
            switch self {
            case .string(let s): return "s:" + s
            case .bool(let b): return b ? "b:1" : "b:0"
            }
        }
    }

    struct Stamped: Equatable, Sendable {
        var value: Value
        var at: Date
    }

    enum Decision: Equatable {
        /// Already the same on both sides.
        case keep
        /// This device's value goes to iCloud.
        case push
        /// iCloud's value replaces this device's.
        case pull
    }

    /// `local` is nil while you have never set the setting on this device: a
    /// default never overrides what you chose on another one.
    static func decide(local: Stamped?, remote: Stamped?) -> Decision {
        switch (local, remote) {
        case (nil, nil):
            return .keep
        case (_?, nil):
            return .push
        case (nil, _?):
            return .pull
        case let (mine?, theirs?):
            if mine.value == theirs.value { return .keep }
            if theirs.at > mine.at { return .pull }
            if mine.at > theirs.at { return .push }
            return theirs.value.order > mine.value.order ? .pull : .push
        }
    }
}

/// Mirrors a few settings through iCloud's key-value store while the library is in
/// iCloud: your name, the language, the summary engine and voice recognition.
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    static let keys = [Pref.myName, Pref.language, Pref.recogniseVoices]
    /// When each of them was last changed on this device.
    static let stampsKey = "syncedSettingsChangedAt"

    private var on = false
    /// The values as last seen, to tell which one a change notification is about.
    private var seen: [String: SettingsMerge.Value] = [:]
    private var observers: [NSObjectProtocol] = []

    private var cloud: NSUbiquitousKeyValueStore { .default }

    func update(on wanted: Bool) {
        guard wanted != on else { return }
        on = wanted
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard wanted else { return }
        seen = currentLocal()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { _ in
                MainActor.assumeIsolated { SettingsSync.shared.mergeAll() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
                MainActor.assumeIsolated { SettingsSync.shared.localChanged() }
            })
        _ = cloud.synchronize()
        mergeAll()
    }

    func mergeAll() {
        guard on else { return }
        let local = currentLocal()
        let stamps = loadStamps()
        for key in Self.keys {
            let mine = local[key].map {
                SettingsMerge.Stamped(value: $0, at: stamps[key].map(Date.init(timeIntervalSince1970:)) ?? .distantPast)
            }
            let theirs = remote(key)
            switch SettingsMerge.decide(local: mine, remote: theirs) {
            case .keep:
                break
            case .push:
                if let mine { push(key, mine) }
            case .pull:
                if let theirs { apply(key, theirs) }
            }
        }
    }

    private func localChanged() {
        guard on else { return }
        let now = currentLocal()
        let changed = Self.keys.filter { now[$0] != seen[$0] }
        guard !changed.isEmpty else { return }
        // First, so the writes below don't count as another change.
        seen = now
        let at = Date()
        var stamps = loadStamps()
        for key in changed { stamps[key] = at.timeIntervalSince1970 }
        saveStamps(stamps)
        for key in changed {
            if let value = now[key] { push(key, SettingsMerge.Stamped(value: value, at: at)) }
        }
    }

    private func apply(_ key: String, _ stamped: SettingsMerge.Stamped) {
        seen[key] = stamped.value
        switch stamped.value {
        case .string(let s): Pref.d.set(s, forKey: key)
        case .bool(let b): Pref.d.set(b, forKey: key)
        }
        var stamps = loadStamps()
        stamps[key] = stamped.at.timeIntervalSince1970
        saveStamps(stamps)
    }

    private func push(_ key: String, _ stamped: SettingsMerge.Stamped) {
        let value: Any
        switch stamped.value {
        case .string(let s): value = s
        case .bool(let b): value = b
        }
        let payload: [String: Any] = ["v": value, "t": stamped.at.timeIntervalSince1970]
        cloud.set(payload, forKey: "pref." + key)
    }

    private func remote(_ key: String) -> SettingsMerge.Stamped? {
        guard let payload = cloud.dictionary(forKey: "pref." + key), let t = payload["t"] as? Double else { return nil }
        let at = Date(timeIntervalSince1970: t)
        if let s = payload["v"] as? String { return SettingsMerge.Stamped(value: .string(s), at: at) }
        if let b = payload["v"] as? Bool { return SettingsMerge.Stamped(value: .bool(b), at: at) }
        return nil
    }

    /// Only settings you have set yourself, not the defaults.
    private func currentLocal() -> [String: SettingsMerge.Value] {
        guard let id = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: id) else { return [:] }
        var out: [String: SettingsMerge.Value] = [:]
        for key in Self.keys {
            if let s = domain[key] as? String {
                out[key] = .string(s)
            } else if let b = domain[key] as? Bool {
                out[key] = .bool(b)
            }
        }
        return out
    }

    private func loadStamps() -> [String: Double] {
        (Pref.d.dictionary(forKey: Self.stampsKey) as? [String: Double]) ?? [:]
    }

    private func saveStamps(_ stamps: [String: Double]) {
        Pref.d.set(stamps, forKey: Self.stampsKey)
    }
}
