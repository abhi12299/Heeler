import Foundation

/// One search over the session transcripts of Agents that are running now.
/// The sessions are named by the ids herdr reports; nothing else on the Host
/// is read.
struct TranscriptSearchRequest: Sendable, Equatable {
    let query: String
    let sessions: [TranscriptSession]
}

/// An Agent kind whose session transcripts this search can read on a Host:
/// where the kind keeps them, and how one of its lines carries a message.
enum TranscriptSource: String, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    /// The source for the Agent a herdr session reference names, if any.
    init?(agent: String) {
        self.init(rawValue: agent)
    }
}

/// One running Agent's own session, as herdr reports it by id.
struct TranscriptSession: Sendable, Equatable {
    let source: TranscriptSource
    let id: String
}

/// The latest message in one Agent's transcript that contains the query.
struct TranscriptSearchHit: Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    let sessionID: String
    let role: Role
    /// The message text around the match, on one line.
    let snippet: String
}

/// Builds the Host script that searches Claude session transcripts and reads
/// its output back. Pure, like `GitProbe`: the transport only runs it.
enum TranscriptSearchProbe {
    static let sessionMarker = "@@heeler-session "
    /// How many matching messages one session returns; the last is shown.
    static let linesPerSession = 3
    /// One session's share of the output, so a pasted log cannot flood it.
    static let bytesPerSession = 200_000

    /// The script for one search, or nil when there is nothing to search.
    ///
    /// Each session is opened by its file name where its own Agent kind
    /// keeps transcripts, so the cost follows the running Agents and never
    /// the sessions stored beside them. grep narrows each file to messages
    /// that hold the query inside a text value; `hits(fromOutput:query:)`
    /// has the last word on what counts.
    static func script(for request: TranscriptSearchRequest) -> Data? {
        let query = cleaned(request.query)
        let sessions = request.sessions.filter { isPlainToken($0.id) }
        guard !query.isEmpty, !sessions.isEmpty else { return nil }
        let stored = jsonEscaped(query)
        var script = """
            LC_ALL=C
            export LC_ALL
            q=\(singleQuoted(stored))

            """
        for source in TranscriptSource.allCases {
            let ids = sessions.filter { $0.source == source }.map(\.id)
            guard !ids.isEmpty else { continue }
            let pattern = source.textValuePattern + patternEscaped(stored)
            let filters = source.messageFilters.map { "      | \($0) \\\n" }.joined()
            script += """
                re=\(singleQuoted(pattern))
                for id in \(ids.joined(separator: " ")); do
                  for f in \(source.fileGlobs.joined(separator: " ")); do
                    [ -f "$f" ] || continue
                    printf '\(sessionMarker)\(source.rawValue) %s\\n' "$id"
                    grep -i -F -e "$q" -- "$f" \\
                \(filters)\
                      | grep -i -E -e "$re" \\
                      | tail -n \(linesPerSession) \\
                      | sed -E \(singleQuoted(source.inlineDataSubstitution)) \\
                      | head -c \(bytesPerSession)
                    printf '\\n'
                    break
                  done
                done

                """
        }
        return Data(script.utf8)
    }

    /// A session id is only ever a file name here, so anything that is not a
    /// plain token is dropped rather than quoted.
    private static func isPlainToken(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.utf8.count <= 128 else { return false }
        func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
        }
        return isAlphanumeric(first)
            && value.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "-" || $0 == "_" }
    }

    private static func cleaned(_ query: String) -> String {
        String(String.UnicodeScalarView(query.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F
        })).trimmingCharacters(in: .whitespaces)
    }

    /// The query as a transcript line stores it inside a JSON string.
    private static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func patternEscaped(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if #".[]()*+?{}|^$\"#.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func singleQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Reads the script's output: a marker line per session whose file was
    /// found, then the transcript lines that matched. A line is a hit only
    /// when the query is in text the user or the Agent wrote.
    static func hits(fromOutput output: Data, query: String) -> [TranscriptSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var hits: [TranscriptSearchHit] = []
        var session: TranscriptSession?
        var latest: TranscriptSearchHit?
        func close() {
            if let latest { hits.append(latest) }
            latest = nil
        }
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix(sessionMarker) {
                close()
                let fields = line.dropFirst(sessionMarker.count).split(separator: " ")
                session = fields.count == 2
                    ? TranscriptSource(rawValue: String(fields[0])).map {
                        TranscriptSession(source: $0, id: String(fields[1]))
                    }
                    : nil
            } else if let session, let hit = hit(in: line, session: session, needle: needle) {
                latest = hit
            }
        }
        close()
        return hits
    }

    private static func hit(
        in line: Substring, session: TranscriptSession, needle: String
    ) -> TranscriptSearchHit? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let message = session.source.message(in: object)
        else { return nil }
        for text in message.texts {
            if let snippet = snippet(of: text, around: needle) {
                return TranscriptSearchHit(
                    sessionID: session.id, role: message.role, snippet: snippet)
            }
        }
        return nil
    }

    /// A row has room for two short lines; the match sits near the start so
    /// it is never the part that gets truncated.
    static let snippetLength = 140
    private static let snippetLead = 40

    private static func snippet(of text: String, around needle: String) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let match = flat.range(of: needle, options: .caseInsensitive) else { return nil }
        guard flat.count > snippetLength else { return flat }
        let start = flat.index(
            match.lowerBound, offsetBy: -snippetLead, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(start, offsetBy: snippetLength, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "")
            + flat[start..<end].trimmingCharacters(in: .whitespaces)
            + (end < flat.endIndex ? "…" : "")
    }
}

/// What each kind's transcript looks like, on the Host and line by line.
extension TranscriptSource {
    /// Where the kind writes a session, as shell globs over `$id`. Only the
    /// file name varies, so no directory is ever walked.
    var fileGlobs: [String] {
        switch self {
        case .claude:
            [
                #""$HOME"/.claude*/projects/*/"$id".jsonl"#,
                #""${CLAUDE_CONFIG_DIR:-/nonexistent}"/projects/*/"$id".jsonl"#,
            ]
        case .codex:
            [#""${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*-"$id".jsonl"#]
        }
    }

    /// greps that keep only lines a person or the Agent wrote as prose.
    var messageFilters: [String] {
        switch self {
        case .claude:
            [
                #"grep -E -e '"type":"(user|assistant)"'"#,
                #"grep -v -F -e '"tool_use_id"' -e '"type":"tool_use"' -e '"isMeta":true' -e '"isSidechain":true'"#,
            ]
        case .codex:
            [
                #"grep -F -e '"type":"response_item","payload":{"type":"message"'"#,
                #"grep -E -e '"role":"(user|assistant)"'"#,
            ]
        }
    }

    /// The start of a pattern that finds the query inside a JSON string
    /// value holding message text.
    var textValuePattern: String {
        switch self {
        case .claude: #""(text|content)":"([^"\\]|\\.)*"#
        case .codex: #""text":"([^"\\]|\\.)*"#
        }
    }

    /// Drops an attached image's bytes from a matching line before it is
    /// sent back.
    var inlineDataSubstitution: String {
        switch self {
        case .claude: #"s/"data":"[A-Za-z0-9+\/=]{64,}"/"data":""/g"#
        case .codex: #"s/"image_url":"data:[^"]{64,}"/"image_url":""/g"#
        }
    }

    /// The role and prose of a transcript line, or nil for a line that is
    /// not a message somebody wrote.
    func message(in object: [String: Any]) -> (role: TranscriptSearchHit.Role, texts: [String])? {
        switch self {
        case .claude:
            guard
                object["isMeta"] as? Bool != true,
                let role = Self.role(object["type"] as? String),
                let message = object["message"] as? [String: Any]
            else { return nil }
            if let text = message["content"] as? String { return (role, [text]) }
            return (role, Self.texts(in: message["content"], ofTypes: ["text"]))
        case .codex:
            guard
                object["type"] as? String == "response_item",
                let payload = object["payload"] as? [String: Any],
                payload["type"] as? String == "message",
                let role = Self.role(payload["role"] as? String)
            else { return nil }
            let texts = Self.texts(in: payload["content"], ofTypes: ["input_text", "output_text"])
            // Codex files what it was told about the Host as user messages,
            // each wrapped in a tag of its own.
            return (role, texts.filter { !Self.isInjectedContext($0) })
        }
    }

    private static func role(_ name: String?) -> TranscriptSearchHit.Role? {
        switch name {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    private static func texts(in content: Any?, ofTypes types: Set<String>) -> [String] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            (block["type"] as? String).map(types.contains) == true ? block["text"] as? String : nil
        }
    }

    /// Text that opens with a lowercase tag, as `<environment_context>` does,
    /// or with the project instructions Codex reads in at the start.
    private static func isInjectedContext(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(<[a-z_]+>|# AGENTS\.md instructions for )"#, options: .regularExpression
        ) != nil
    }
}
