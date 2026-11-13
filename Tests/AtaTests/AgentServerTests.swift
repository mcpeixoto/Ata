@testable import Ata
import XCTest

/// `Ata --mcp`: the JSON-RPC handler, against fixture meetings in a temp folder.
/// The stdin loop is a shell around `AgentMCP.respond`; these tests call that.
final class AgentServerTests: XCTestCase {
    private var savedAccess: Any?
    private var savedName: Any?
    private var made: [URL] = []
    private let ritaID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let unnamedID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        FilesTests.setUp()
        savedAccess = UserDefaults.standard.object(forKey: Pref.agentAccess)
        savedName = UserDefaults.standard.object(forKey: Pref.myName)
        UserDefaults.standard.set(true, forKey: Pref.agentAccess)
        UserDefaults.standard.set("Alex", forKey: Pref.myName)
        try writeFixtures()
    }

    override func tearDownWithError() throws {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        if let savedAccess {
            UserDefaults.standard.set(savedAccess, forKey: Pref.agentAccess)
        } else {
            UserDefaults.standard.removeObject(forKey: Pref.agentAccess)
        }
        if let savedName {
            UserDefaults.standard.set(savedName, forKey: Pref.myName)
        } else {
            UserDefaults.standard.removeObject(forKey: Pref.myName)
        }
        try super.tearDownWithError()
    }

    func testInitializeEchoesASupportedProtocolAndFallsBack() throws {
        for version in ["2025-06-18", "2025-03-26", "2024-11-05"] {
            let params: [String: Any] = ["protocolVersion": version, "capabilities": [String: Any](),
                                         "clientInfo": ["name": "t", "version": "0"]]
            let result = try result(of: rpc(method: "initialize", params: params))
            XCTAssertEqual(result["protocolVersion"] as? String, version)
            let caps = try XCTUnwrap(result["capabilities"] as? [String: Any])
            XCTAssertNotNil(caps["tools"] as? [String: Any])
            let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
            XCTAssertEqual(info["name"] as? String, "ata")
            XCTAssertNotNil(info["version"] as? String)
        }
        let unknown = try result(of: rpc(method: "initialize", params: ["protocolVersion": "1999-01-01"]))
        XCTAssertEqual(unknown["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(unknown["instructions"] as? String,
                       "Read-only access to the meetings recorded with Ata on this Mac.")
    }

    func testANotificationGetsNoResponseAndPingGetsAnEmptyObject() throws {
        XCTAssertNil(AgentMCP.respond(to: rpc(method: "notifications/initialized", id: nil)))
        XCTAssertNil(AgentMCP.respond(to: rpc(method: "notifications/cancelled", id: nil)))
        let ping = try result(of: rpc(method: "ping"))
        XCTAssertTrue(ping.isEmpty)
    }

    func testUnknownMethodAndGarbage() throws {
        let (code, message) = try errorCode(of: rpc(method: "nope"))
        XCTAssertEqual(code, -32601)
        XCTAssertEqual(message, "Method not found")

        let response = try XCTUnwrap(AgentMCP.respond(to: Data("this is not json".utf8)))
        XCTAssertFalse(response.contains(0x0A))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let err = try XCTUnwrap(obj["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? Int, -32700)
        XCTAssertEqual(err["message"] as? String, "Parse error")
        XCTAssertTrue(obj["id"] is NSNull)
    }

    func testBadParamsAreAProtocolError() throws {
        let (code, message) = try errorCode(of: rpc(method: "tools/call", params: [String]()))
        XCTAssertEqual(code, -32602)
        XCTAssertEqual(message, "Invalid params")
    }

    func testToolsListReturnsTheFourTools() throws {
        let result = try result(of: rpc(method: "tools/list"))
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["list_meetings", "get_meeting", "search_meetings", "list_people"])
        XCTAssertEqual(tools.count, 4)
        let descriptions = [
            "list_meetings": "List this Mac's meetings, newest first.",
            "get_meeting": "Read one meeting, including its notes and transcript.",
            "search_meetings": "Search meetings for every word of a query.",
            "list_people": "List people Ata knows by name.",
        ]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            XCTAssertEqual(tool["description"] as? String, descriptions[name])
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }
    }

    func testToolsStayEnglishWhenTheLocaleWouldBePortuguese() throws {
        // Bundle.main reads AppleLanguages at process launch. This suite has no
        // way to relaunch in Portuguese, so the strings the server sends must
        // be absent from the Portuguese table: that table is what a Portuguese
        // Mac would return if they went through L().
        let table = try portugueseTable()
        let listed = try result(of: rpc(method: "tools/list"))
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        let descriptions = [
            "List this Mac's meetings, newest first.",
            "Read one meeting, including its notes and transcript.",
            "Search meetings for every word of a query.",
            "List people Ata knows by name.",
        ]
        XCTAssertEqual(Set(tools.compactMap { $0["description"] as? String }), Set(descriptions))
        for description in descriptions {
            XCTAssertFalse(table.contains("\"\(description)\""), description)
        }

        UserDefaults.standard.set(false, forKey: Pref.agentAccess)
        let sentence = "Agent access is off. Turn it on in Ata's Settings, under Connect your agent."
        let (text, isError, _) = try callTool("list_meetings")
        XCTAssertTrue(isError)
        XCTAssertEqual(text, sentence)
        XCTAssertFalse(table.contains("\"\(sentence)\""))
        XCTAssertFalse(table.contains("O acesso do agente está desligado"))
        for key in [
            "Read-only access to the meetings recorded with Ata on this Mac.",
            "Ata has no tool by that name.",
            "Say which words to search for.",
            "No meetings match.",
            "No transcript",
            "No summary",
            "%@ — %d meetings, latest %@",
            "%@ — %d meeting, latest %@",
            "Say which meeting.",
            "The limit has to be a whole number.",
            "That date has to be ISO 8601.",
            "No named people yet.",
            "That value has to be true or false.",
            "No meeting with that id.",
            "The transcript is cut at about 150,000 characters, through %@.",
            "The rest is still in iCloud.",
        ] {
            XCTAssertFalse(table.contains("\"\(key)\""), key)
        }
    }

    func testCallsFailClosedWhenAgentAccessIsOff() throws {
        UserDefaults.standard.set(false, forKey: Pref.agentAccess)
        let listed = try result(of: rpc(method: "tools/list"))
        XCTAssertEqual((listed["tools"] as? [[String: Any]])?.count, 4)
        let initialized = try result(of: rpc(method: "initialize", params: ["protocolVersion": "2025-06-18"]))
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-06-18")

        let sentence = "Agent access is off. Turn it on in Ata's Settings, under Connect your agent."
        for name in ["list_meetings", "get_meeting", "search_meetings", "list_people"] {
            var args: [String: Any] = [:]
            if name == "get_meeting" { args["id"] = "agent-mid" }
            if name == "search_meetings" { args["query"] = "orcamento" }
            let (text, isError, raw) = try callTool(name, args)
            XCTAssertTrue(isError, name)
            XCTAssertEqual(text, sentence, name)
            XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("\"error\""))
        }
    }

    func testABadArgumentIsAToolError() throws {
        let (text, isError, raw) = try callTool("list_meetings", ["limit": "many"])
        XCTAssertTrue(isError)
        XCTAssertEqual(text, "The limit has to be a whole number.")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertNil(obj["error"])
        XCTAssertNotNil(obj["result"])

        let (unknown, unknownError, _) = try callTool("nope")
        XCTAssertTrue(unknownError)
        XCTAssertEqual(unknown, "Ata has no tool by that name.")

        let (badDate, badDateError, _) = try callTool("list_meetings", ["after": "yesterday"])
        XCTAssertTrue(badDateError)
        XCTAssertEqual(badDate, "That date has to be ISO 8601.")
    }

    func testListMeetingsIsNewestFirstAndFilters() throws {
        let all = try callTool("list_meetings", ["query": "agentorder", "limit": 10]).text
        let rows = lines(all)
        XCTAssertEqual(rows.count, 3)
        let iNew = try XCTUnwrap(index(of: "agent-new", in: all))
        let iMid = try XCTUnwrap(index(of: "agent-mid", in: all))
        let iOld = try XCTUnwrap(index(of: "agent-old", in: all))
        XCTAssertLessThan(iNew, iMid)
        XCTAssertLessThan(iMid, iOld)
        XCTAssertTrue(all.contains("Budget review"))
        XCTAssertTrue(all.contains("Rita Almeida"))
        XCTAssertFalse(all.contains("S1"))
        XCTAssertTrue(all.contains(localStamp("2025-06-01T12:00:00Z")))
        XCTAssertTrue(all.contains("10 min"))
        XCTAssertTrue(all.contains("Transcript"))
        XCTAssertTrue(all.contains("Summary"))

        let one = try callTool("list_meetings", ["query": "agentorder", "limit": 1]).text
        XCTAssertEqual(lines(one).count, 1)
        XCTAssertTrue(one.contains("agent-new"))

        let window = try callTool("list_meetings", [
            "query": "agentorder",
            "after": "2025-01-01T00:00:00Z",
            "before": "2026-01-01T00:00:00Z",
        ]).text
        XCTAssertTrue(window.contains("agent-mid"))
        XCTAssertFalse(window.contains("agent-old"))
        XCTAssertFalse(window.contains("agent-new"))

        let early = try callTool("list_meetings", [
            "query": "agentorder", "before": "2024-12-31T23:59:59Z",
        ]).text
        XCTAssertTrue(early.contains("agent-old"))
        XCTAssertFalse(early.contains("agent-mid"))
    }

    func testListMeetingsClampsTheLimit() throws {
        let base = date("3100-01-01T00:00:00Z")
        for i in 0..<101 {
            let id = String(format: "agent-lim-%03d", i)
            let at = base.addingTimeInterval(Double(i) * 86_400)
            _ = try makeMeeting(id: id, title: "agentlim \(i)", at: at)
        }
        defer { removeLimitMeetings() }

        let twenty = try callTool("list_meetings", ["query": "agentlim"]).text
        XCTAssertEqual(lines(twenty).count, 20)
        XCTAssertTrue(twenty.contains("agent-lim-100"))
        XCTAssertFalse(twenty.contains("agent-lim-080"))

        let one = try callTool("list_meetings", ["query": "agentlim", "limit": 1]).text
        XCTAssertEqual(lines(one).count, 1)
        XCTAssertTrue(one.contains("agent-lim-100"))

        let clamped = try callTool("list_meetings", ["query": "agentlim", "limit": 1000]).text
        let rows = lines(clamped)
        XCTAssertEqual(rows.count, 100)
        XCTAssertTrue(clamped.contains("agent-lim-100"))
        XCTAssertTrue(clamped.contains("agent-lim-001"))
        XCTAssertFalse(clamped.contains("agent-lim-000"))
    }

    func testGetMeetingReadsWhatTheAppShows() throws {
        let (text, isError, _) = try callTool("get_meeting", ["id": "agent-mid"])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("We agreed the next steps."))
        XCTAssertTrue(text.contains("Lembrar de enviar a ata."))
        XCTAssertTrue(text.contains("[00:10] Rita Almeida: O orçamento ficou aprovado"))
        XCTAssertTrue(text.contains("check the budget"))
        XCTAssertFalse(text.contains("S1"))
        XCTAssertTrue(text.contains(localStamp("2025-06-01T12:00:00Z")))
        XCTAssertTrue(text.contains("Duration: 10 min"))
        XCTAssertTrue(text.contains("Participants: Alex, Rita Almeida"))
        XCTAssertTrue(text.contains("## Summary"))
        XCTAssertTrue(text.contains("## Notes"))
        XCTAssertTrue(text.contains("## Moments you marked"))
        XCTAssertTrue(text.contains("## Transcript"))

        let hidden = try callTool("get_meeting", ["id": "agent-mid", "transcript": false]).text
        XCTAssertTrue(hidden.contains("We agreed the next steps."))
        XCTAssertTrue(hidden.contains("Lembrar de enviar a ata."))
        XCTAssertFalse(hidden.contains("## Transcript"))

        let (missing, missingError, _) = try callTool("get_meeting", ["id": "no-such-agent-meeting"])
        XCTAssertTrue(missingError)
        XCTAssertEqual(missing, "No meeting with that id.")

        let (blank, blankError, _) = try callTool("get_meeting")
        XCTAssertTrue(blankError)
        XCTAssertEqual(blank, "Say which meeting.")
    }

    func testGetMeetingCapsALongTranscript() throws {
        var segments: [StoredTranscript.Line] = []
        for i in 0..<200 {
            let body: String
            if i == 0 { body = "START_MARKER " + String(repeating: "a", count: 900) }
            else if i == 199 { body = "END_MARKER " + String(repeating: "b", count: 900) }
            else { body = String(repeating: "c", count: 1000) }
            let start = i * 5_000
            segments.append(.init(start: start, end: start + 400, text: body, speaker: Speakers.me))
        }
        let meeting = try makeMeeting(id: "agent-long", title: "Long one", at: date("2090-01-01T00:00:00Z"))
        let stored = StoredTranscript(segments: segments, coarse: false, summary: "Short.", engine: "local", model: "large-v3")
        try stored.save(to: meeting.storedTranscriptURL)
        defer { try? FileManager.default.removeItem(at: meeting.dir) }

        let (text, isError, _) = try callTool("get_meeting", ["id": "agent-long"])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("START_MARKER"))
        XCTAssertFalse(text.contains("END_MARKER"))
        XCTAssertTrue(text.contains("The transcript is cut at about 150,000 characters, through "))
        XCTAssertNotNil(text.range(of: #"through \d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertGreaterThan(text.count, 100_000)
        XCTAssertLessThan(text.count, 160_000)
    }

    func testSearchRequiresEveryWordAndIgnoresCaseAndDiacritics() throws {
        for query in ["orcamento", "ORÇAMENTO", "Orçamento"] {
            let (text, isError, _) = try callTool("search_meetings", ["query": query])
            XCTAssertFalse(isError, query)
            XCTAssertTrue(text.contains("agent-mid"), query)
            XCTAssertTrue(text.contains("orçamento"), query)
            XCTAssertTrue(text.contains("[00:10] Rita Almeida:"), query)
            XCTAssertFalse(text.contains("S1"), query)
        }
        let both = try callTool("search_meetings", ["query": "orcamento aprovado"]).text
        XCTAssertTrue(both.contains("agent-mid"))
        let missing = try callTool("search_meetings", ["query": "orcamento zebra"]).text
        XCTAssertFalse(missing.contains("agent-mid"))

        let notes = try callTool("search_meetings", ["query": "LEMBRAR ata"]).text
        XCTAssertTrue(notes.contains("agent-mid"))
        XCTAssertTrue(notes.contains("Lembrar"))

        let one = try callTool("search_meetings", ["query": "agentsearchtoken", "limit": 1]).text
        XCTAssertTrue(one.contains("agent-new"))
        XCTAssertFalse(one.contains("agent-mid"))
        XCTAssertTrue(one.contains("agentsearchtoken"))

        let (empty, emptyError, _) = try callTool("search_meetings")
        XCTAssertTrue(emptyError)
        XCTAssertEqual(empty, "Say which words to search for.")
    }

    func testListPeopleNamesAndCounts() throws {
        let (text, isError, _) = try callTool("list_people")
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("Rita Almeida — 2 meetings, latest \(localStamp("2999-01-01T12:00:00Z"))"))
        XCTAssertFalse(text.contains("Voice 4242"))
    }

    func testTheHandlerDoesNotWrite() throws {
        let before = inventory()
        _ = AgentMCP.respond(to: rpc(method: "initialize", params: ["protocolVersion": "2025-06-18"]))
        _ = AgentMCP.respond(to: rpc(method: "notifications/initialized", id: nil))
        _ = AgentMCP.respond(to: rpc(method: "ping"))
        _ = AgentMCP.respond(to: rpc(method: "tools/list"))
        _ = try callTool("list_meetings", ["query": "agentorder"])
        _ = try callTool("get_meeting", ["id": "agent-mid"])
        _ = try callTool("get_meeting", ["id": "agent-mid", "transcript": false])
        _ = try callTool("search_meetings", ["query": "orcamento"])
        _ = try callTool("list_people")
        _ = AgentMCP.respond(to: rpc(method: "nope"))
        _ = AgentMCP.respond(to: Data("not json".utf8))
        XCTAssertEqual(inventory(), before)
    }

    func testEachResponseIsASingleLine() throws {
        let raw = try callTool("get_meeting", ["id": "agent-mid"]).raw
        XCTAssertFalse(raw.contains(0x0A))
        XCTAssertFalse(raw.contains(0x0D))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\n"), "the meeting text has newlines; the JSON must escape them")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("\"isError\":false"))
    }

    func testConfigurationUsesTheExecutablePath() {
        let path = "/Applications/Ata.app/Contents/MacOS/Ata"
        let json = AgentConfiguration.json(executable: path)
        XCTAssertTrue(json.contains("\"command\": \"\(path)\""))
        XCTAssertTrue(json.contains("[\"--mcp\"]"))
        XCTAssertEqual(AgentConfiguration.claudeCode(executable: path),
                       "claude mcp add ata -- \"\(path)\" --mcp")
    }

    // MARK: Fixtures

    private func writeFixtures() throws {
        let old = try makeMeeting(id: "agent-old", title: "agentorder standup", at: date("2024-06-01T12:00:00Z"))
        let mid = try makeMeeting(id: "agent-mid", title: "agentorder Budget review", at: date("2025-06-01T12:00:00Z"))
        let new = try makeMeeting(id: "agent-new", title: "agentorder planning", at: date("2999-01-01T12:00:00Z"))

        var edited = mid
        edited.bookmarks = [Bookmark(ms: 10_000, note: "check the budget")]
        Library.save(edited)

        let stored = StoredTranscript(segments: [
            .init(start: 0, end: 2_000, text: "Hello from me", speaker: Speakers.me),
            .init(start: 10_000, end: 12_000, text: "O orçamento ficou aprovado", speaker: "S1"),
        ], coarse: false, summary: "We agreed the next steps.", engine: "local", model: "large-v3")
        try stored.save(to: mid.storedTranscriptURL)
        try """
        # Budget review

        ## Summary

        We agreed the next steps.

        ---

        **[00:10] Rita Almeida:** O orçamento ficou aprovado
        """.write(to: mid.transcriptURL, atomically: true, encoding: .utf8)
        try "Lembrar de enviar a ata. agentsearchtoken".write(to: mid.notesURL, atomically: true, encoding: .utf8)
        try "agentsearchtoken".write(to: new.notesURL, atomically: true, encoding: .utf8)

        let speakers = MeetingVoices(
            speakers: [MeetingSpeaker(label: "S1", embedding: [1, 0, 0], seconds: 5, voiceID: ritaID)],
            turns: [SpeakerTurn(start: 10_000, end: 12_000, label: "S1")])
        try speakers.save(for: mid)

        try FileManager.default.createDirectory(at: Paths.voicesDir, withIntermediateDirectories: true)
        let rita = Voice(id: ritaID, name: "Rita Almeida", centroid: [1, 0, 0], observations: 1,
                         meetingIDs: [mid.id, new.id], sample: nil,
                         firstSeen: date("2025-06-01T12:00:00Z"), lastSeen: date("2999-01-01T12:00:00Z"),
                         number: 7)
        let unnamed = Voice(id: unnamedID, name: nil, centroid: [0, 1, 0], observations: 1,
                            meetingIDs: [old.id], sample: nil,
                            firstSeen: date("2024-06-01T12:00:00Z"), lastSeen: date("2024-06-01T12:00:00Z"),
                            number: 4242)
        let encoder = VoiceLibrary.encoder()
        let ritaURL = Paths.voicesDir.appendingPathComponent("\(ritaID.uuidString).json")
        let unnamedURL = Paths.voicesDir.appendingPathComponent("\(unnamedID.uuidString).json")
        try encoder.encode(rita).write(to: ritaURL)
        try encoder.encode(unnamed).write(to: unnamedURL)
        made.append(ritaURL)
        made.append(unnamedURL)
    }

    @discardableResult
    private func makeMeeting(id: String, title: String, at: Date) throws -> Meeting {
        let meeting = Meeting(id: id, startedAt: at, endedAt: at.addingTimeInterval(600), duration: 600,
                              app: title, status: .done, error: nil)
        try FileManager.default.createDirectory(at: meeting.dir, withIntermediateDirectories: true)
        Library.save(meeting)
        made.append(meeting.dir)
        return meeting
    }

    private func removeLimitMeetings() {
        for i in 0..<101 {
            let id = String(format: "agent-lim-%03d", i)
            try? FileManager.default.removeItem(at: Paths.meetingsDir.appendingPathComponent(id))
        }
    }

    // MARK: Protocol

    private func rpc(method: String, id: Int? = 1, params: Any? = nil) -> Data {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { obj["id"] = id }
        if let params { obj["params"] = params }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func result(of data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let raw = try XCTUnwrap(AgentMCP.respond(to: data), file: file, line: line)
        XCTAssertFalse(raw.contains(0x0A), "response must be one line", file: file, line: line)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], file: file, line: line)
        return try XCTUnwrap(obj["result"] as? [String: Any], file: file, line: line)
    }

    private func errorCode(of data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> (Int, String) {
        let raw = try XCTUnwrap(AgentMCP.respond(to: data), file: file, line: line)
        XCTAssertFalse(raw.contains(0x0A), file: file, line: line)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], file: file, line: line)
        let err = try XCTUnwrap(obj["error"] as? [String: Any], file: file, line: line)
        return (try XCTUnwrap(err["code"] as? Int, file: file, line: line),
                try XCTUnwrap(err["message"] as? String, file: file, line: line))
    }

    private func callTool(_ name: String, _ arguments: [String: Any] = [:],
                          file: StaticString = #filePath, line: UInt = #line) throws -> (text: String, isError: Bool, raw: Data) {
        let raw = try XCTUnwrap(AgentMCP.respond(to: rpc(method: "tools/call", params: ["name": name, "arguments": arguments])),
                                file: file, line: line)
        XCTAssertFalse(raw.contains(0x0A), "response must be one line", file: file, line: line)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], file: file, line: line)
        let result = try XCTUnwrap(obj["result"] as? [String: Any], file: file, line: line)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], file: file, line: line)
        let text = try XCTUnwrap(content.first?["text"] as? String, file: file, line: line)
        let isError = try XCTUnwrap(result["isError"] as? Bool, file: file, line: line)
        return (text, isError, raw)
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func index(of id: String, in text: String) -> Int? {
        lines(text).firstIndex { $0.contains(id) }
    }

    private func date(_ text: String) -> Date {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)!
    }

    /// Same clock the server prints: `yyyy-MM-dd HH:mm`, local time, no locale.
    private func localStamp(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date(text))
    }

    private func portugueseTable() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/pt.lproj/Localizable.strings")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private struct Stamp: Equatable {
        var modified: Date
        var size: UInt64
    }

    private func inventory() -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        for root in [Paths.meetingsDir, Paths.supportDir] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let urls = [root] + (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            for url in urls {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let modified = attrs[.modificationDate] as? Date else { continue }
                let size = (attrs[.size] as? UInt64) ?? UInt64(attrs[.size] as? Int ?? 0)
                out[url.path] = Stamp(modified: modified, size: size)
            }
        }
        return out
    }
}
