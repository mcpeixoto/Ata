import Foundation

/// English for the agent. `String(format:)` otherwise follows the Mac's locale,
/// and this text is never shown in Ata's UI.
private func agentEnglish(_ format: String, _ args: CVarArg...) -> String {
    String(format: format, locale: Locale(identifier: "en_US_POSIX"), arguments: args)
}

/// `Ata --mcp`: the meetings on this Mac, for an agent, over MCP on stdin.
///
/// The agent starts this process and talks JSON-RPC on stdin/stdout. Nothing
/// listens on a port, and this mode never writes, moves, downloads or deletes:
/// `Library.loadAll()` is not used, because it creates the meetings folder and
/// asks iCloud to fetch a `meeting.json` that isn't here yet.
enum AgentServer {
    static var requested: Bool { CommandLine.arguments.contains("--mcp") }

    /// Reads stdin until it closes, writes one JSON object per response line,
    /// and exits. Logs, if any, stay on stderr: stdout is the protocol.
    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A blank line is the client's trailing newline, not a message.
            guard !trimmed.isEmpty else { continue }
            guard var response = AgentMCP.respond(to: Data(trimmed.utf8)) else { continue }
            response.append(0x0A)
            FileHandle.standardOutput.write(response)
        }
        exit(0)
    }
}

/// The block a person pastes into Claude, Cursor or another MCP client.
enum AgentConfiguration {
    static func json(executable path: String) -> String {
        """
        {
          "mcpServers": {
            "ata": { "command": "\(escaped(path))", "args": ["--mcp"] }
          }
        }
        """
    }

    /// The command half of the Settings hint. Not translated; the sentence around it is.
    static func claudeCode(executable path: String) -> String {
        "claude mcp add ata -- \"\(path)\" --mcp"
    }

    private static func escaped(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

/// One JSON-RPC message in, an optional response out. A notification (no `id`)
/// returns nil. Meeting access goes through `Library` and `Paths`, which follow
/// `ATA_MEETINGS_DIR`.
enum AgentMCP {
    static let textCap = 150_000
    private static let protocols: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let fallbackProtocol = "2025-06-18"

    static func respond(to request: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: request) else {
            return failure(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let obj = json as? [String: Any] else {
            return failure(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let method = obj["method"] as? String else {
            return failure(id: obj["id"] ?? NSNull(), code: -32600, message: "Invalid Request")
        }
        // A notification has no id, and gets no response. `"id": null` still counts as absent.
        guard let id = obj["id"], !(id is NSNull) else { return nil }
        switch method {
        case "initialize":
            return initialize(id: id, params: obj["params"])
        case "ping":
            return success(id: id, result: [String: Any]())
        case "tools/list":
            return toolsList(id: id, params: obj["params"])
        case "tools/call":
            return toolsCall(id: id, params: obj["params"])
        default:
            return failure(id: id, code: -32601, message: "Method not found")
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func initialize(id: Any, params: Any?) -> Data? {
        let fields: [String: Any]
        switch arguments(params) {
        case .invalid: return failure(id: id, code: -32602, message: "Invalid params")
        case .missing: fields = [:]
        case .object(let obj): fields = obj
        }
        let requested = fields["protocolVersion"] as? String ?? ""
        let protocolVersion = protocols.contains(requested) ? requested : fallbackProtocol
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "ata", "version": version],
            "instructions": "Read-only access to the meetings recorded with Ata on this Mac.",
        ]
        return success(id: id, result: result)
    }

    private static func toolsList(id: Any, params: Any?) -> Data? {
        if case .invalid = arguments(params) {
            return failure(id: id, code: -32602, message: "Invalid params")
        }
        let tools: [[String: Any]] = [
            tool("list_meetings",
                 "List this Mac's meetings, newest first.",
                 properties: [
                    "limit": ["type": "integer"],
                    "after": ["type": "string"],
                    "before": ["type": "string"],
                    "query": ["type": "string"],
                 ]),
            tool("get_meeting",
                 "Read one meeting, including its notes and transcript.",
                 properties: [
                    "id": ["type": "string"],
                    "transcript": ["type": "boolean"],
                 ],
                 required: ["id"]),
            tool("search_meetings",
                 "Search meetings for every word of a query.",
                 properties: [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"],
                 ],
                 required: ["query"]),
            tool("list_people",
                 "List people Ata knows by name.",
                 properties: [:]),
        ]
        return success(id: id, result: ["tools": tools])
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }

    private static func toolsCall(id: Any, params: Any?) -> Data? {
        let fields: [String: Any]
        switch arguments(params) {
        case .object(let obj): fields = obj
        case .missing, .invalid: return failure(id: id, code: -32602, message: "Invalid params")
        }
        guard let name = fields["name"] as? String, !name.isEmpty else {
            return failure(id: id, code: -32602, message: "Invalid params")
        }
        let arguments: [String: Any]
        if fields["arguments"] == nil || fields["arguments"] is NSNull {
            arguments = [:]
        } else if let args = fields["arguments"] as? [String: Any] {
            arguments = args
        } else {
            return failure(id: id, code: -32602, message: "Invalid params")
        }
        // Off by default. Listing the tools still works, so the agent can say why
        // a call did nothing instead of looking like a broken server.
        guard UserDefaults.standard.bool(forKey: Pref.agentAccess) else {
            return toolResult(id: id, text: "Agent access is off. Turn it on in Ata's Settings, under Connect your agent.",
                              isError: true)
        }
        let read = AgentRead()
        switch name {
        case "list_meetings": return listMeetings(id: id, args: arguments, read: read)
        case "get_meeting": return getMeeting(id: id, args: arguments, read: read)
        case "search_meetings": return searchMeetings(id: id, args: arguments, read: read)
        case "list_people": return listPeople(id: id, read: read)
        default:
            return toolResult(id: id, text: "Ata has no tool by that name.", isError: true)
        }
    }

    private static func listMeetings(id: Any, args: [String: Any], read: AgentRead) -> Data? {
        let limit: Int
        switch boundedInt(args["limit"], default: 20, max: 100) {
        case .bad(let message): return toolResult(id: id, text: message, isError: true)
        case .ok(let n): limit = n
        }
        let after: AgentRead.When?
        switch read.parseWhen(args["after"]) {
        case .bad(let message): return toolResult(id: id, text: message, isError: true)
        case .ok(let when): after = when
        }
        let before: AgentRead.When?
        switch read.parseWhen(args["before"]) {
        case .bad(let message): return toolResult(id: id, text: message, isError: true)
        case .ok(let when): before = when
        }
        if args["query"] != nil && !(args["query"] is String) {
            return toolResult(id: id, text: "Say which words to search for.", isError: true)
        }
        let query = AgentRead.words(of: args["query"] as? String ?? "")
        var meetings = read.all()
        if let after { meetings = meetings.filter { read.starts($0, onOrAfter: after) } }
        if let before { meetings = meetings.filter { read.starts($0, onOrBefore: before) } }
        if !query.isEmpty { meetings = meetings.filter { read.matches(query, $0) } }
        let shown = meetings.prefix(limit)
        let text = shown.isEmpty
            ? "No meetings yet"
            : shown.map { read.listLine($0) }.joined(separator: "\n")
        return toolResult(id: id, text: text, isError: false)
    }

    private static func getMeeting(id: Any, args: [String: Any], read: AgentRead) -> Data? {
        guard let raw = args["id"] as? String, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return toolResult(id: id, text: "Say which meeting.", isError: true)
        }
        let includeTranscript: Bool
        if let flag = args["transcript"] {
            guard let value = jsonBool(flag) else {
                return toolResult(id: id, text: "That value has to be true or false.", isError: true)
            }
            includeTranscript = value
        } else {
            includeTranscript = true
        }
        let meetingID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let meeting = read.meeting(meetingID) else {
            return toolResult(id: id, text: "No meeting with that id.", isError: true)
        }
        return toolResult(id: id, text: read.meetingText(meeting, transcript: includeTranscript), isError: false)
    }

    private static func searchMeetings(id: Any, args: [String: Any], read: AgentRead) -> Data? {
        guard let query = args["query"] as? String else {
            return toolResult(id: id, text: "Say which words to search for.", isError: true)
        }
        let words = AgentRead.words(of: query)
        guard !words.isEmpty else {
            return toolResult(id: id, text: "Say which words to search for.", isError: true)
        }
        let limit: Int
        switch boundedInt(args["limit"], default: 10, max: 50) {
        case .bad(let message): return toolResult(id: id, text: message, isError: true)
        case .ok(let n): limit = n
        }
        let hits = read.all().filter { read.matches(words, $0) }.prefix(limit)
        if hits.isEmpty { return toolResult(id: id, text: "No meetings match.", isError: false) }
        let text = hits.map { meeting -> String in
            var lines = ["\(meeting.id) — \(meeting.title) — \(read.stamp(meeting.startedAt))"]
            lines.append(contentsOf: read.excerpts(meeting, words: words).map { "- \($0)" })
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return toolResult(id: id, text: text, isError: false)
    }

    private static func listPeople(id: Any, read: AgentRead) -> Data? {
        let people = read.namedPeople()
        if people.isEmpty { return toolResult(id: id, text: "No named people yet.", isError: false) }
        let text = people.map { voice -> String in
            let name = voice.name ?? ""
            let when = read.stamp(voice.lastSeen)
            if voice.meetings == 1 {
                return agentEnglish("%@ — %d meeting, latest %@", name, voice.meetings, when)
            }
            return agentEnglish("%@ — %d meetings, latest %@", name, voice.meetings, when)
        }.joined(separator: "\n")
        return toolResult(id: id, text: text, isError: false)
    }

    // MARK: JSON-RPC

    /// Missing params are fine. A value that isn't an object is not.
    private enum Arguments {
        case missing
        case object([String: Any])
        case invalid
    }

    private static func arguments(_ params: Any?) -> Arguments {
        if params == nil || params is NSNull { return .missing }
        guard let obj = params as? [String: Any] else { return .invalid }
        return .object(obj)
    }

    private enum Parsed<T> {
        case ok(T)
        case bad(String)
    }

    private static func boundedInt(_ value: Any?, default fallback: Int, max maxValue: Int) -> Parsed<Int> {
        guard let value else { return .ok(fallback) }
        guard let n = jsonInt(value) else { return .bad("The limit has to be a whole number.") }
        return .ok(min(maxValue, max(0, n)))
    }

    private static func jsonInt(_ value: Any) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, d <= Double(Int.max), d >= Double(Int.min) else { return nil }
        return n.intValue
    }

    private static func jsonBool(_ value: Any) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func toolResult(id: Any, text: String, isError: Bool) -> Data? {
        success(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])
    }

    private static func success(id: Any, result: Any) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func failure(id: Any, code: Int, message: String) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One object, no raw newline. `JSONSerialization` escapes newlines inside strings.
    private static func encode(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj)
    }
}

/// Reads the library. Constructing it does not create folders or download iCloud files.
private struct AgentRead {
    struct When {
        var date: Date
        /// `yyyy-MM-dd`, so "before" includes the whole of that day.
        var dateOnly: Bool
    }

    let library: VoiceLibrary
    let myName: String
    /// `yyyy-MM-dd HH:mm` in local time. `en_US_POSIX` keeps the hour cycle and
    /// the separators from following the Mac's language.
    let stampFormatter: DateFormatter

    init() {
        // persist: false so a legacy voices.json or an unnumbered voice is not
        // rewritten just because an agent asked who was in a meeting.
        library = VoiceLibrary(persist: false)
        myName = Pref.myNameOrDefault
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        stampFormatter = formatter
    }

    func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    func all() -> [Meeting] {
        ids().compactMap { meeting($0) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// The folder name when `meeting.json` is still in iCloud, without asking for it.
    func meeting(_ id: String) -> Meeting? {
        let dir = Library.folder(for: id)
        let meta = dir.appendingPathComponent("meeting.json")
        if CloudFiles.state(of: meta) == .inCloud {
            return Library.placeholder(id: id, in: dir)
        }
        return Library.load(id)
    }

    func parseWhen(_ value: Any?) -> AgentMCPParsed<When?> {
        guard let value else { return .ok(nil) }
        guard let text = value as? String else { return .bad("That date has to be ISO 8601.") }
        if text.isEmpty { return .ok(nil) }
        if let date = internetDate(text) { return .ok(When(date: date, dateOnly: false)) }
        if let date = dayDate(text) { return .ok(When(date: date, dateOnly: true)) }
        return .bad("That date has to be ISO 8601.")
    }

    func starts(_ meeting: Meeting, onOrAfter when: When) -> Bool {
        meeting.startedAt >= when.date
    }

    func starts(_ meeting: Meeting, onOrBefore when: When) -> Bool {
        if when.dateOnly {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let end = calendar.date(byAdding: .day, value: 1, to: when.date) ?? when.date
            return meeting.startedAt < end
        }
        return meeting.startedAt <= when.date
    }

    static func words(of query: String) -> [String] {
        query.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }

    func matches(_ words: [String], _ meeting: Meeting) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let text = haystack(meeting)
        return words.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    func listLine(_ meeting: Meeting) -> String {
        let markdown = markdown(of: meeting)
        let summary = summaryText(of: meeting, markdown: markdown)
        let people = participants(of: meeting)
        let hasTranscript = markdown != nil || CloudFiles.state(of: meeting.storedTranscriptURL) == .local
        let minutes: String
        if let duration = meeting.duration {
            minutes = agentEnglish("%d min", max(1, Int((duration / 60).rounded())))
        } else {
            minutes = "—"
        }
        var parts = [
            meeting.id,
            meeting.title,
            stamp(meeting.startedAt),
            minutes,
            people.isEmpty ? "—" : people.joined(separator: ", "),
            hasTranscript ? "Transcript" : "No transcript",
            summary.isEmpty ? "No summary" : "Summary",
        ]
        if inCloud(meeting) { parts.append("The rest is still in iCloud.") }
        return parts.joined(separator: " — ")
    }

    func meetingText(_ meeting: Meeting, transcript: Bool) -> String {
        let map = speakerMap(meeting)
        let names = Speakers.names(map: map, library: library, myName: myName)
        let excluded = Speakers.leftOut(map: map, library: library)
        let stored = loadStored(meeting)
        let markdown = markdown(of: meeting)

        var header: [String] = ["# \(meeting.title)", "", stamp(meeting.startedAt)]
        if let duration = meeting.duration {
            header.append(agentEnglish("Duration: %d min", max(1, Int((duration / 60).rounded()))))
        }
        let people = participants(of: meeting)
        if !people.isEmpty {
            header.append(agentEnglish("Participants: %@", people.joined(separator: ", ")))
        }
        let summary = stored?.summary ?? markdown.flatMap { summarySection($0) } ?? ""
        if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            header.append("")
            header.append("## Summary")
            header.append("")
            header.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let notes = notes(of: meeting).trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            header.append("")
            header.append("## Notes")
            header.append("")
            header.append(notes)
        }

        var rows: [(time: String, line: String)] = []
        if let stored {
            let blocks = Transcriber.blocks(stored.excluding(excluded))
            if let moments = momentsText(meeting.bookmarks ?? [], blocks: blocks, names: names) {
                header.append("")
                header.append(moments)
            }
            if transcript {
                header.append("")
                header.append("## Transcript")
                for block in blocks {
                    let time = Transcriber.timestamp(block.start)
                    rows.append((time, "[\(time)] \(names(block.speaker)): \(block.text)"))
                }
            }
        } else if transcript {
            let parsed = transcriptRows(of: meeting)
            if !parsed.isEmpty {
                header.append("")
                header.append("## Transcript")
                for row in parsed {
                    rows.append((row.time, "[\(row.time)] \(row.name): \(row.text)"))
                }
            }
        }

        return capped(header.joined(separator: "\n"), rows: rows, cloud: inCloud(meeting))
    }

    func excerpts(_ meeting: Meeting, words: [String]) -> [String] {
        var out: [String] = []
        func add(_ text: String?) {
            guard out.count < 3, let text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !out.contains(trimmed) else { return }
            out.append(trimmed)
        }
        for row in transcriptRows(of: meeting) {
            guard let body = snippet(row.text, words: words) else { continue }
            add("[\(row.time)] \(row.name): \(body)")
        }
        add(snippet(notes(of: meeting), words: words))
        add(snippet(summaryText(of: meeting, markdown: markdown(of: meeting)), words: words))
        add(snippet(meeting.title, words: words))
        if out.isEmpty, let markdown = markdown(of: meeting) {
            add(snippet(markdown, words: words))
        }
        return out
    }

    func namedPeople() -> [Voice] {
        library.voices.filter { voice in
            let name = voice.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !name.isEmpty && !voice.isExcluded
        }.sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
    }

    // MARK: Files

    /// Same folders as `Library.loadAll()`, without creating one or downloading.
    private func ids() -> [String] {
        let staged = Library.stagedIDs()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.meetingsDir,
                                                                 includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        let folderIDs = dirs.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.lastPathComponent)
        return staged + folderIDs.filter { !staged.contains($0) }
    }

    /// Title, people, notes, summary and transcript. The transcript is the
    /// markdown (or the segment text), never the word timings.
    private func haystack(_ meeting: Meeting) -> String {
        let markdown = markdown(of: meeting)
        return [
            meeting.title,
            participants(of: meeting).joined(separator: "\n"),
            notes(of: meeting),
            summaryText(of: meeting, markdown: markdown),
            transcriptBody(of: meeting, markdown: markdown),
        ].joined(separator: "\n")
    }

    private func transcriptBody(of meeting: Meeting, markdown: String?) -> String {
        if let markdown, !markdown.isEmpty { return markdown }
        guard let stored = loadStored(meeting) else { return "" }
        return stored.segments.map(\.text).joined(separator: "\n")
    }

    private func participants(of meeting: Meeting) -> [String] {
        if meeting.isPlaceholder { return [] }
        if let map = speakerMap(meeting) {
            let names = Speakers.names(map: map, library: library, myName: myName)
            let excluded = Speakers.leftOut(map: map, library: library)
            var people = [myName]
            let labels = map.speakers.map(\.label) + map.turns.map(\.label)
            for label in labels where !excluded.contains(label) {
                let name = names(label)
                if !people.contains(name) { people.append(name) }
            }
            return people
        }
        return participants(in: markdown(of: meeting))
    }

    private func participants(in markdown: String?) -> [String] {
        guard let markdown else { return [] }
        // The file was written with the app's own heading, which follows the
        // language Ata was using then. This match is not text we send.
        let prefix = L("Participants: %@").replacingOccurrences(of: "%@", with: "")
        for line in markdown.split(separator: "\n") {
            let text = String(line)
            guard let range = text.range(of: prefix) else { continue }
            let rest = text[range.upperBound...]
            let names = rest.split(separator: "·").first.map(String.init) ?? String(rest)
            return names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    private func speakerMap(_ meeting: Meeting) -> MeetingVoices? {
        guard CloudFiles.state(of: meeting.speakersURL) != .inCloud else { return nil }
        return MeetingVoices.load(for: meeting)
    }

    private func loadStored(_ meeting: Meeting) -> StoredTranscript? {
        guard CloudFiles.state(of: meeting.storedTranscriptURL) == .local else { return nil }
        return StoredTranscript.load(from: meeting.storedTranscriptURL)
    }

    /// Nil when the file is still in iCloud: reading it would download it.
    private func markdown(of meeting: Meeting) -> String? {
        guard let url = meeting.existingTranscriptURL, CloudFiles.state(of: url) == .local else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func notes(of meeting: Meeting) -> String {
        guard CloudFiles.state(of: meeting.notesURL) == .local else { return "" }
        return MeetingNotes.load(for: meeting)
    }

    private func summaryText(of meeting: Meeting, markdown: String?) -> String {
        if let markdown, let section = summarySection(markdown), !section.isEmpty { return section }
        guard CloudFiles.state(of: meeting.storedTranscriptURL) == .local,
              let raw = try? String(contentsOf: meeting.storedTranscriptURL, encoding: .utf8) else { return "" }
        return summaryField(in: raw) ?? ""
    }

    private func summarySection(_ markdown: String) -> String? {
        // Same as the participants line: find the heading already in the file.
        let heading = "## " + L("Summary")
        guard let range = markdown.range(of: heading) else { return nil }
        var lines: [String] = []
        var started = false
        for lineSub in markdown[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            if !started {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                started = true
            }
            if line.hasPrefix("## ") || line.trimmingCharacters(in: .whitespaces) == "---" { break }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The `"summary"` value, read as text so a search doesn't decode word timings.
    private func summaryField(in json: String) -> String? {
        var search = json.startIndex
        while let key = json.range(of: "\"summary\"", range: search..<json.endIndex) {
            var i = key.upperBound
            while i < json.endIndex, json[i].isWhitespace { i = json.index(after: i) }
            guard i < json.endIndex, json[i] == ":" else {
                search = key.upperBound
                continue
            }
            i = json.index(after: i)
            while i < json.endIndex, json[i].isWhitespace { i = json.index(after: i) }
            guard i < json.endIndex, json[i] == "\"" else { return nil }
            i = json.index(after: i)
            var out = ""
            while i < json.endIndex {
                let c = json[i]
                if c == "\\" {
                    let next = json.index(after: i)
                    guard next < json.endIndex else { break }
                    switch json[next] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    default: out.append(json[next])
                    }
                    i = json.index(after: next)
                    continue
                }
                if c == "\"" { break }
                out.append(c)
                i = json.index(after: i)
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func transcriptRows(of meeting: Meeting) -> [(time: String, name: String, text: String)] {
        if let markdown = markdown(of: meeting) {
            return markdown.split(separator: "\n").compactMap { line in
                parseSpeakerLine(String(line)).map { ($0.time, $0.name, $0.text) }
            }
        }
        guard let stored = loadStored(meeting) else { return [] }
        let map = speakerMap(meeting)
        let names = Speakers.names(map: map, library: library, myName: myName)
        let excluded = Speakers.leftOut(map: map, library: library)
        return Transcriber.blocks(stored.excluding(excluded)).map { block in
            (Transcriber.timestamp(block.start), names(block.speaker), block.text)
        }
    }

    private func parseSpeakerLine(_ line: String) -> (time: String, name: String, text: String)? {
        guard line.hasPrefix("**["), let close = line.range(of: "]") else { return nil }
        let timeStart = line.index(line.startIndex, offsetBy: 3)
        guard timeStart < close.lowerBound else { return nil }
        let time = String(line[timeStart..<close.lowerBound])
        let rest = line[close.upperBound...]
        guard let mark = rest.range(of: ":**") else { return nil }
        let name = rest[..<mark.lowerBound].trimmingCharacters(in: .whitespaces)
        let text = rest[mark.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !time.isEmpty, !name.isEmpty else { return nil }
        return (time, String(name), String(text))
    }

    private func snippet(_ text: String, words: [String]) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard let word = words.first(where: { text.range(of: $0, options: options) != nil }),
              let range = text.range(of: word, options: options) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
        var excerpt = String(text[start..<end])
        if start > text.startIndex { excerpt = "…" + excerpt }
        if end < text.endIndex { excerpt += "…" }
        return excerpt
    }

    private func momentsText(_ bookmarks: [Bookmark], blocks: [StoredTranscript.Line],
                             names: (String) -> String) -> String? {
        guard !bookmarks.isEmpty else { return nil }
        let starts = blocks.map(\.start), ends = blocks.map(\.end)
        var lines = ["## Moments you marked", ""]
        for bookmark in bookmarks.sorted(by: { $0.ms < $1.ms }) {
            var item = "- [\(Transcriber.timestamp(bookmark.ms))]"
            if let index = Bookmark.nearest(to: bookmark.ms, starts: starts, ends: ends) {
                item += " \(names(blocks[index].speaker)): \(blocks[index].text)"
            }
            if let note = bookmark.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                item += " — \(note)"
            }
            lines.append(item)
        }
        return lines.joined(separator: "\n")
    }

    private func inCloud(_ meeting: Meeting) -> Bool {
        if meeting.isPlaceholder { return true }
        let urls = meeting.transcriptFiles + [meeting.storedTranscriptURL, meeting.notesURL, meeting.speakersURL]
        return urls.contains { CloudFiles.state(of: $0) == .inCloud }
    }

    private func capped(_ header: String, rows: [(time: String, line: String)], cloud: Bool) -> String {
        var kept: [String] = []
        var lastTime: String?
        var cut = false
        for row in rows {
            let next = kept + [row.line]
            if (header + "\n" + next.joined(separator: "\n")).count > AgentMCP.textCap {
                cut = true
                break
            }
            kept.append(row.line)
            lastTime = row.time
        }
        var text = header
        if !kept.isEmpty { text += "\n" + kept.joined(separator: "\n") }
        if cut {
            text += "\n\n" + agentEnglish("The transcript is cut at about 150,000 characters, through %@.", lastTime ?? "00:00")
        } else if text.count > AgentMCP.textCap {
            let notice = "\n\n" + agentEnglish("The transcript is cut at about 150,000 characters, through %@.", "00:00")
            let room = max(0, AgentMCP.textCap - notice.count)
            text = String(text.prefix(room)) + notice
        }
        if cloud { text += "\n\nThe rest is still in iCloud." }
        return text
    }

    private func internetDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: text) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    private func dayDate(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        return parser.date(from: text)
    }
}

/// `Optional` can't be the failure of a parse that also returns nil for "absent",
/// so the date parser uses this instead of `Optional`.
private enum AgentMCPParsed<T> {
    case ok(T)
    case bad(String)
}
