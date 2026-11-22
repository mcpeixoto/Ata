@testable import Ata
import PDFKit
import XCTest

/// Custom templates, asking across meetings, and PDF/Word export. None of these
/// call the on-device model. Disk tests stay in a temporary folder.
final class ProFeaturesTests: XCTestCase {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ata-pro-features-\(UUID().uuidString)", isDirectory: true)

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("ATA_MEETINGS_DIR", root.appendingPathComponent("meetings").path, 1)
        setenv("ATA_SUPPORT_DIR", root.appendingPathComponent("support").path, 1)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Custom templates

    func testTemplateJSONRoundTrips() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let template = CustomTemplate(id: id, name: "Sprint", instructions: "Name the blockers.",
                                      sections: ["Blockers", "Next"])
        let data = try JSONEncoder().encode(template)
        XCTAssertEqual(try JSONDecoder().decode(CustomTemplate.self, from: data), template)

        let dir = try folder()
        try TemplateLibrary.save([template], to: dir, at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(TemplateLibrary.load(from: dir), [template])
        let again = try TemplateLibrary.decode(TemplateLibrary.encode(
            TemplateSnapshot(savedAt: Date(timeIntervalSince1970: 10), templates: [template])))
        XCTAssertEqual(again.templates, [template])
        XCTAssertEqual(again.savedAt, Date(timeIntervalSince1970: 10))
    }

    func testInstructionsStopAtOneThousandCharacters() throws {
        let exact = String(repeating: "c", count: 1_000)
        XCTAssertEqual(CustomTemplate(name: "N", instructions: exact, sections: []).instructions, exact)

        let long = String(repeating: "b", count: 1_001)
        XCTAssertEqual(CustomTemplate(name: "N", instructions: long, sections: []).instructions.count, 1_000)
        XCTAssertEqual(CustomTemplate(name: "N", instructions: long, sections: []).instructions, String(repeating: "b", count: 1_000))

        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","name":"N","instructions":"\#(long)","sections":[]}"#
        let decoded = try JSONDecoder().decode(CustomTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.instructions.count, 1_000)
    }

    func testACorruptTemplatesFileReadsAsNone() throws {
        let dir = try folder()
        try "{".write(to: TemplateLibrary.file(in: dir), atomically: true, encoding: .utf8)
        XCTAssertEqual(TemplateLibrary.load(from: dir), [])
    }

    func testThePromptCarriesInstructionsHeadingsAndVocabulary() {
        let custom = CustomTemplate(name: "Budget", instructions: "Always list the customer's budget first.",
                                    sections: ["Budget", "Next step"])
        let prompt = SummaryPrompt.part(myName: "Alex", choice: .custom(custom), vocabulary: ["Copilot"])
        XCTAssertTrue(prompt.contains("Always list the customer's budget first."), prompt)
        XCTAssertTrue(prompt.contains("Budget"), prompt)
        XCTAssertTrue(prompt.contains("Next step"), prompt)
        XCTAssertTrue(prompt.contains("Copilot"), prompt)
        XCTAssertTrue(prompt.contains("Alex"), prompt)
    }

    func testABuiltInTemplateStillSteersThePrompt() {
        let prompt = SummaryPrompt.part(myName: "Alex", choice: .builtIn(.sales), vocabulary: [])
        XCTAssertTrue(prompt.contains("sales call"), prompt)
        XCTAssertFalse(prompt.contains("Organize the notes under these headings"), prompt)
    }

    /// The five built-in templates stay free. A custom one does not.
    func testAFreeUserFallsBackToTheStandardTemplate() {
        let custom = CustomTemplate(name: "Budget", instructions: "Always list the customer's budget first.",
                                    sections: ["Budget", "Next step"])
        XCTAssertEqual(TemplateChoice.forUse(.custom(custom), isPro: false), .builtIn(.standard))
        XCTAssertEqual(TemplateChoice.forUse(.custom(custom), isPro: true), .custom(custom))
        XCTAssertEqual(TemplateChoice.forUse(.builtIn(.sales), isPro: false), .builtIn(.sales))

        let used = TemplateChoice.forUse(.custom(custom), isPro: false)
        let prompt = SummaryPrompt.part(myName: "Alex", choice: used, vocabulary: [])
        XCTAssertFalse(prompt.contains("customer's budget"), prompt)
        XCTAssertEqual(prompt, SummaryPrompt.part(myName: "Alex", choice: .builtIn(.standard), vocabulary: []))
    }

    func testTheNewerTemplateCopyWins() {
        let id = UUID()
        let local = TemplateSnapshot(savedAt: Date(timeIntervalSince1970: 1),
                                     templates: [CustomTemplate(id: id, name: "N", instructions: "I", sections: [])])
        var remote = local
        remote.savedAt = Date(timeIntervalSince1970: 2)
        remote.templates = [CustomTemplate(id: id, name: "Other", instructions: "J", sections: ["A"])]
        XCTAssertEqual(TemplateLibrary.decide(local: local, remote: remote), .pull)
        XCTAssertEqual(TemplateLibrary.decide(local: remote, remote: local), .push)
        remote.templates = local.templates
        XCTAssertEqual(TemplateLibrary.decide(local: local, remote: remote), .keep)
        XCTAssertEqual(TemplateLibrary.decide(local: nil, remote: nil), .keep)
        XCTAssertEqual(TemplateLibrary.decide(local: local, remote: nil), .push)
        XCTAssertEqual(TemplateLibrary.decide(local: nil, remote: local), .pull)
    }

    func testANewerCloudCopyReplacesLocalTemplates() throws {
        let dir = try folder()
        let older = CustomTemplate(id: UUID(), name: "Old", instructions: "First.", sections: ["A"])
        let newer = CustomTemplate(id: UUID(), name: "New", instructions: "Second.", sections: ["B"])
        try TemplateLibrary.save([older], to: dir, at: Date(timeIntervalSince1970: 100))
        let remote = TemplateSnapshot(savedAt: Date(timeIntervalSince1970: 200), templates: [newer])
        let cloud = MemoryTemplateCloud()
        cloud.stored = (try TemplateLibrary.encode(remote), remote.savedAt)
        try TemplateLibrary.reconcile(directory: dir, cloud: cloud, iCloudOn: true)
        XCTAssertEqual(TemplateLibrary.load(from: dir), [newer])
        XCTAssertEqual(cloud.writes, 0)
    }

    func testANewerLocalCopyIsPushedWhenICloudIsOn() throws {
        let dir = try folder()
        let local = CustomTemplate(id: UUID(), name: "Local", instructions: "Mine.", sections: [])
        try TemplateLibrary.save([local], to: dir, at: Date(timeIntervalSince1970: 300))
        let remote = TemplateSnapshot(savedAt: Date(timeIntervalSince1970: 100), templates: [])
        let cloud = MemoryTemplateCloud()
        cloud.stored = (try TemplateLibrary.encode(remote), remote.savedAt)
        try TemplateLibrary.reconcile(directory: dir, cloud: cloud, iCloudOn: true)
        XCTAssertEqual(cloud.writes, 1)
        XCTAssertEqual(TemplateLibrary.load(from: dir), [local])
        XCTAssertEqual(try TemplateLibrary.decode(cloud.stored!.json).templates, [local])
    }

    func testSyncDoesNothingWhenICloudIsOff() throws {
        let dir = try folder()
        let local = CustomTemplate(id: UUID(), name: "Local", instructions: "Mine.", sections: [])
        try TemplateLibrary.save([local], to: dir, at: Date(timeIntervalSince1970: 300))
        let cloud = MemoryTemplateCloud()
        cloud.stored = ("{}", Date(timeIntervalSince1970: 900))
        try TemplateLibrary.reconcile(directory: dir, cloud: cloud, iCloudOn: false)
        XCTAssertEqual(cloud.writes, 0)
        XCTAssertEqual(TemplateLibrary.load(from: dir), [local])
    }

    func testATemplatePayloadOverTheKeyValueLimitIsNotWritten() {
        XCTAssertNotNil(TemplateLibrary.cloudPayload(json: "[]", at: Date(timeIntervalSince1970: 1)))
        let huge = String(repeating: "x", count: TemplateLibrary.cloudByteLimit + 1)
        XCTAssertNil(TemplateLibrary.cloudPayload(json: huge, at: Date(timeIntervalSince1970: 1)))
    }

    // MARK: Ask your meetings

    func testRankPrefersTheChunkThatSharesMoreWords() {
        let ranked = AskIndex.rank(question: "invoice overdue roadmap", meetings: [roadmap, billing])
        XCTAssertEqual(ranked.map(\.meetingTitle), ["Billing", "Roadmap"])
        XCTAssertEqual(ranked.first?.meetingID, "billing")
        XCTAssertEqual(ranked.first?.startMs, 12_000)
    }

    func testRankKeepsAtMostEightAndDropsATieAtTheEnd() {
        let meetings = (0..<9).map { i in
            AskSource(id: "m\(i)", title: "Meeting \(i)",
                      transcript: "**[00:0\(i)] Alex:** uniqueword\(i) appears here only.")
        }
        let question = (0..<9).map { "uniqueword\($0)" }.joined(separator: " ")
        let ranked = AskIndex.rank(question: question, meetings: meetings)
        XCTAssertEqual(ranked.count, 8)
        XCTAssertFalse(ranked.contains { $0.text.contains("uniqueword8") })
        XCTAssertTrue(ranked.contains { $0.text.contains("uniqueword0") })
    }

    func testRankStaysInsideTheContextBudget() {
        let padding = String(repeating: "padding ", count: 100)
        let meetings = (0..<8).map { i in
            AskSource(id: "\(i)", title: "T\(i)",
                      transcript: "**[00:0\(i)] Alex:** keyword \(padding)")
        }
        let ranked = AskIndex.rank(question: "keyword", meetings: meetings)
        let total = ranked.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, AskIndex.contextBudget)
        XCTAssertGreaterThan(ranked.count, 0)
        XCTAssertLessThan(ranked.count, AskIndex.maximum)
    }

    func testRankIgnoresCaseAndAccentsAndAnEmptyQuestion() {
        let meeting = AskSource(id: "1", title: "Plan",
                                transcript: "**[00:02] Ana:** A reunião ficou para sexta.")
        XCTAssertEqual(AskIndex.rank(question: "REUNIAO", meetings: [meeting]).count, 1)
        XCTAssertTrue(AskIndex.rank(question: "  ", meetings: [meeting]).isEmpty)
        XCTAssertTrue(AskIndex.rank(question: "a", meetings: [meeting]).isEmpty)
    }

    func testChunksStayWithTheirMeeting() {
        let longLine = String(repeating: "word ", count: 300)
        let meeting = AskSource(id: "a", title: "Long", transcript: """
        **[00:01] Alex:** \(longLine)
        **[02:00] Sam:** \(longLine)
        """)
        let other = AskSource(id: "b", title: "Short",
                              transcript: "**[00:05] Rita:** hello there friends")
        let chunks = AskIndex.chunks(meetings: [meeting, other], maxCharacters: 800)
        XCTAssertGreaterThan(chunks.filter { $0.meetingTitle == "Long" }.count, 1)
        XCTAssertEqual(chunks.filter { $0.meetingID == "b" }.map(\.startMs), [5_000])
        XCTAssertEqual(chunks.filter { $0.meetingTitle == "Short" }.map(\.text), ["Rita: hello there friends"])
        let joined = chunks.filter { $0.meetingID == "a" }.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.contains("word"))
        XCTAssertTrue(joined.contains("Alex:") || joined.contains("Sam:"))
    }

    func testCitationsReadTheTitleAndTheTime() {
        let reply = "The invoice is overdue [Billing · 00:12]. Friday is the plan [Roadmap · 1:02:03]."
        let found = AskCitations.parse(reply)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0], AskCitation(title: "Billing", stamp: "00:12", milliseconds: 12_000))
        XCTAssertEqual(found[1], AskCitation(title: "Roadmap", stamp: "1:02:03", milliseconds: 3_723_000))
        XCTAssertTrue(AskCitations.parse("no citation here").isEmpty)
        XCTAssertTrue(AskCitations.parse("[Billing · noon]").isEmpty)
    }

    /// The text the model would be given. This does not call the model.
    func testTheAskPromptNamesTheQuestionTheExcerptAndTheCitationForm() {
        let ranked = AskIndex.rank(question: "invoice", meetings: [billing])
        let prompt = AskMeetings.prompt(question: "What is overdue?", chunks: ranked)
        XCTAssertTrue(prompt.contains("What is overdue?"), prompt)
        XCTAssertTrue(prompt.contains("invoice"), prompt)
        XCTAssertTrue(prompt.contains("[Billing · 00:12]"), prompt)
    }

    // MARK: PDF and Word

    func testPDFHasAPageAndTheLongTranscriptHasMore() throws {
        let data = DocumentExport.pdf(shortMeeting)
        XCTAssertGreaterThan(DocumentExport.pageCount(data), 0)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("Ship on Friday"), text)
        XCTAssertTrue(text.contains("Bring the beta list"), text)
        XCTAssertTrue(text.contains("Alex"), text)
        XCTAssertTrue(text.contains("00:03"), text)

        let long = DocumentExport.pdf(longMeeting)
        XCTAssertGreaterThan(DocumentExport.pageCount(long), DocumentExport.pageCount(data))
        XCTAssertGreaterThan(DocumentExport.pageCount(long), 1)
    }

    func testDocxIsAZipWithTheDocumentAndTheTranscript() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("notes.docx")
        let data = DocumentExport.docx(shortMeeting)
        try data.write(to: url)
        let listing = try run(["/usr/bin/unzip", "-l", url.path])
        XCTAssertTrue(listing.contains("[Content_Types].xml"), listing)
        XCTAssertTrue(listing.contains("word/document.xml"), listing)
        let tested = try run(["/usr/bin/unzip", "-t", url.path])
        XCTAssertTrue(tested.contains("No errors"), tested)
        let xml = try run(["/usr/bin/unzip", "-p", url.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("Ship on Friday"), xml)
        XCTAssertTrue(xml.contains("Bring the beta list"), xml)
        XCTAssertTrue(xml.contains("Alex"), xml)
        XCTAssertTrue(xml.contains("00:03"), xml)
        XCTAssertTrue(xml.contains("w:pStyle"), xml)
        XCTAssertTrue(xml.contains("668CFF"), xml)
    }

    func testDocxEscapesReservedCharacters() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("odd.docx")
        let document = ExportDocument(title: "Q&A <sync>", notes: "", summary: "", lines: [])
        try DocumentExport.docx(document).write(to: url)
        let xml = try run(["/usr/bin/unzip", "-p", url.path, "word/document.xml"])
        XCTAssertTrue(xml.contains("Q&amp;A &lt;sync&gt;"), xml)
        XCTAssertFalse(xml.contains("<sync>"), xml)
    }

    // MARK: Fixtures

    private let billing = AskSource(
        id: "billing", title: "Billing",
        transcript: "**[00:12] Rita:** The invoice for March is overdue and billing must chase it.")
    private let roadmap = AskSource(
        id: "roadmap", title: "Roadmap",
        transcript: "**[03:05] Sam:** The launch roadmap slips if the page is not ready.")

    private var shortMeeting: ExportDocument {
        ExportDocument(
            title: "Weekly sync",
            notes: "Bring the beta list.",
            summary: "Ship on Friday.",
            lines: [
                ExportLine(startMs: 3_000, speaker: "Alex", isMe: true, text: "Let's ship it on Friday."),
                ExportLine(startMs: 11_000, speaker: "Sam", isMe: false, text: "I'll send the notes."),
            ])
    }

    private var longMeeting: ExportDocument {
        ExportDocument(
            title: "Long",
            notes: "",
            summary: "",
            lines: (0..<200).map { i in
                ExportLine(startMs: i * 5_000,
                           speaker: i % 2 == 0 ? "Alex" : "Sam",
                           isMe: i % 2 == 0,
                           text: "This is sentence \(i) about the launch plan and the notes we still owe the team today.")
            })
    }

    @discardableResult
    private func run(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output
    }
}

private final class PresentedFeatures {
    var features: [ProFeature] = []
}

private final class MemoryTemplateCloud: TemplateCloudStore {
    var stored: (json: String, at: Date)?
    var writes = 0
    func payload() -> (json: String, at: Date)? { stored }
    func write(json: String, at: Date) {
        writes += 1
        stored = (json, at)
    }
}

@MainActor
final class ProGateTests: XCTestCase {
    private let suite = "ai.interactive.ata.tests.progate"

    override func tearDown() {
        ProGate.presentPaywall = { _ in }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func testAllowsFollowsIsPro() {
        let access = ProAccess()
        XCTAssertFalse(access.allows(.documentExport))
        XCTAssertFalse(access.allows(.customTemplates))
        XCTAssertFalse(access.allows(.askMeetings))
        access.setStoreKit(active: true, expires: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(access.allows(.documentExport))
        XCTAssertTrue(access.allows(.askMeetings))
        XCTAssertTrue(access.allows(.customTemplates))
    }

    func testALockedExportCountsAndPresentsThePaywall() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let presented = PresentedFeatures()
        ProGate.presentPaywall = { presented.features.append($0) }

        XCTAssertFalse(ProGate.lockedTap(.documentExport, isPro: false, defaults: defaults))
        XCTAssertEqual(presented.features, [.documentExport])
        XCTAssertEqual(defaults.integer(forKey: Funnel.featureLocked(.documentExport).storageKey), 1)

        XCTAssertTrue(ProGate.lockedTap(.documentExport, isPro: true, defaults: defaults))
        XCTAssertEqual(presented.features, [.documentExport], "an unlocked tap does not open the paywall again")
        XCTAssertEqual(defaults.integer(forKey: Funnel.featureLocked(.documentExport).storageKey), 1)
    }
}
