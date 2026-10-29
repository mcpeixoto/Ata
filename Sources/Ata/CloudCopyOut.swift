import Foundation

/// Turning iCloud off: brings the library in iCloud back to this device before
/// Ata moves to this device's folder. On an iPhone the originals were removed
/// once their copy was uploaded, and on either device meetings recorded or
/// changed in iCloud since exist nowhere else, so switching without this would
/// leave the library looking empty or old.
///
/// The same care as `CloudMigration`, the other way round: each file is
/// downloaded, copied under a hidden name, compared byte for byte, and only
/// then given its name. Nothing in iCloud is changed or removed. A file changed
/// both here and in iCloud keeps this device's version and gets iCloud's beside
/// it, and a folder by the same name that holds another meeting is never written
/// into. The ledger `CloudMigration` keeps is brought up to date, so turning
/// iCloud on again doesn't copy everything back as changes.
struct CloudCopyOut: Sendable {
    /// The meetings folder in iCloud.
    let cloud: URL
    /// This device's meetings folder.
    let local: URL
    let ledgerURL: URL
    /// How long to wait for one meeting's files to download.
    var timeout: TimeInterval = 10 * 60
    /// Fetches files still in iCloud; true when all are here. Swapped in tests.
    var download: @Sendable ([URL], TimeInterval) async -> Bool = { await CloudFiles.download($0, timeout: $1) }

    private var ledgerStore: CloudMigration {
        CloudMigration(source: local, destination: cloud, ledgerURL: ledgerURL)
    }

    // MARK: What is left

    /// Meeting folders in iCloud, by name.
    func cloudFolders() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { CloudLibrary.isDirectory($0) }.map(\.lastPathComponent).sorted()
    }

    /// The folder on this device that holds the copy of iCloud's `name`, by the ledger.
    private static func localName(of name: String, in ledger: CloudMigration.Ledger) -> String? {
        ledger.meetings.first { $0.value.target == name }?.key
    }

    /// Folders in iCloud that this device has no copy of as they are now.
    func pending() -> [String] {
        let ledger = ledgerStore.loadLedger()
        return cloudFolders().filter { name in
            guard let mine = Self.localName(of: name, in: ledger), let entry = ledger.meetings[mine],
                  CloudLibrary.isDirectory(local.appendingPathComponent(mine, isDirectory: true)) else { return true }
            return CloudMigration.stamps(of: cloud.appendingPathComponent(name, isDirectory: true)) != entry.copied
        }
    }

    var isComplete: Bool { pending().isEmpty }

    /// Every file in `folder` by path inside it, counting one iCloud hasn't
    /// downloaded yet (on iPhone, a hidden `.<name>.icloud`) under its real name.
    static func files(in folder: URL) -> [String] {
        var out = Set<String>()
        for relative in FileManager.default.subpaths(atPath: folder.path) ?? [] {
            var parts = relative.split(separator: "/").map(String.init)
            guard var name = parts.popLast(), !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(".icloud".count))
            } else if name.hasPrefix(".") || name.hasSuffix(".partial") {
                continue
            }
            let path = (parts + [name]).joined(separator: "/")
            if CloudLibrary.isDirectory(folder.appendingPathComponent(path)) { continue }
            out.insert(path)
        }
        return out.sorted()
    }

    // MARK: Copying

    /// Copies whatever is pending. `shouldContinue` is asked between meetings.
    func run(shouldContinue: @escaping @Sendable () -> Bool = { true },
             progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> CloudMigration.Outcome {
        var outcome = CloudMigration.Outcome()
        let todo = pending()
        progress(0, todo.count)
        for (i, name) in todo.enumerated() {
            guard shouldContinue() else {
                outcome.stopped = true
                break
            }
            let folder = cloud.appendingPathComponent(name, isDirectory: true)
            let files = Self.files(in: folder).map { folder.appendingPathComponent($0) }
            if await download(files, timeout) {
                do {
                    try copy(name)
                    outcome.copied.append(name)
                } catch {
                    NSLog("Ata: could not copy \(name) out of iCloud, the copy there is untouched: \(error.localizedDescription)")
                    outcome.failed.append(name)
                }
            } else {
                NSLog("Ata: \(name) did not download from iCloud; it stays there")
                outcome.failed.append(name)
            }
            progress(i + 1, todo.count)
        }
        return outcome
    }

    /// One downloaded meeting folder, into this device's folder.
    func copy(_ name: String) throws {
        CloudMigration.running.lock()
        defer { CloudMigration.running.unlock() }
        let fm = FileManager.default
        let store = ledgerStore
        var ledger = store.loadLedger()
        let folder = cloud.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)

        let mapped = Self.localName(of: name, in: ledger)
        let mine = mapped ?? unusedName(for: name, copyOf: folder)
        let target = local.appendingPathComponent(mine, isDirectory: true)
        if CloudLibrary.isDirectory(target) {
            let entry = mapped.flatMap { ledger.meetings[$0] }
            for relative in Self.files(in: folder) {
                try bring(relative, from: folder, into: target, lastCopied: entry?.files[relative])
            }
        } else {
            // Hidden while it's incomplete.
            let partial = local.appendingPathComponent(".\(mine).partial", isDirectory: true)
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
            do {
                try fm.copyItem(at: folder, to: partial)
                guard CloudMigration.verified(partial, against: folder) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
                }
                try fm.moveItem(at: partial, to: target)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
        }
        ledger.meetings[mine] = CloudMigration.Entry(target: name, files: CloudMigration.stamps(of: target),
                                                     copied: CloudMigration.stamps(of: folder))
        try store.saveLedger(ledger)
    }

    /// `name` unless a folder here by that name holds something else, then
    /// `name 2`, `name 3`… A folder that already holds the same files is this one.
    private func unusedName(for name: String, copyOf folder: URL) -> String {
        var candidate = name
        var n = 2
        while FileManager.default.fileExists(atPath: local.appendingPathComponent(candidate).path) {
            if CloudMigration.verified(local.appendingPathComponent(candidate, isDirectory: true), against: folder) {
                return candidate
            }
            candidate = "\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// One file of a meeting this device already has a folder for. A file it
    /// lacks, or one unchanged here since it was last copied, takes iCloud's
    /// version; one changed here too keeps this device's, with iCloud's beside it.
    private func bring(_ relative: String, from folder: URL, into target: URL,
                       lastCopied: CloudMigration.Stamp?) throws {
        let source = folder.appendingPathComponent(relative)
        let destination = target.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            try CloudMigration.copyFile(source, to: destination)
            return
        }
        if CloudMigration.sameContents(source, destination) { return }
        if let lastCopied, CloudMigration.stamp(of: destination) == lastCopied {
            try CloudMigration.copyFile(source, to: destination)
        } else {
            let dir = destination.deletingLastPathComponent()
            let aside = dir.appendingPathComponent(Conflicts.unusedAsideName(for: destination.lastPathComponent, in: dir))
            try CloudMigration.copyFile(source, to: aside)
        }
    }

    // MARK: Voices

    /// Voice files from iCloud that this device lacks or has an older copy of.
    /// iCloud's is the voice as both devices last left it. Returns the files
    /// that could not be copied.
    func copyVoices(from cloudVoices: URL, to localVoices: URL) async -> [String] {
        let names = Self.files(in: cloudVoices).filter { !$0.contains("/") }
        var failed: [String] = []
        for name in names {
            let source = cloudVoices.appendingPathComponent(name)
            guard await download([source], timeout) else {
                failed.append(name)
                continue
            }
            let destination = localVoices.appendingPathComponent(name)
            do {
                if !CloudMigration.sameContents(source, destination) {
                    try CloudMigration.copyFile(source, to: destination)
                }
            } catch {
                failed.append(name)
            }
        }
        return failed
    }
}
