import Foundation

/// One search over the session transcripts of Agents that are running now.
/// The sessions are named by the ids herdr reports; nothing else on the Host
/// is read.
struct TranscriptSearchRequest: Sendable, Equatable {
    let query: String
    let sessionIDs: [String]
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
    /// Each session is opened by its file name under the Host's Claude
    /// config directories, so the cost follows the running Agents and never
    /// the sessions stored beside them. grep narrows each file to messages
    /// that hold the query inside a text value; `hits(fromOutput:query:)`
    /// has the last word on what counts.
    static func script(for request: TranscriptSearchRequest) -> Data? {
        let query = cleaned(request.query)
        let sessionIDs = request.sessionIDs.filter(isPlainToken)
        guard !query.isEmpty, !sessionIDs.isEmpty else { return nil }
        let stored = jsonEscaped(query)
        let pattern = #""(text|content)":"([^"\\]|\\.)*"# + patternEscaped(stored)
        return Data("""
            LC_ALL=C
            export LC_ALL
            q=\(singleQuoted(stored))
            re=\(singleQuoted(pattern))
            for id in \(sessionIDs.joined(separator: " ")); do
              for f in "$HOME"/.claude*/projects/*/"$id".jsonl \\
                "${CLAUDE_CONFIG_DIR:-/nonexistent}"/projects/*/"$id".jsonl; do
                [ -f "$f" ] || continue
                printf '\(sessionMarker)%s\\n' "$id"
                grep -i -F -e "$q" -- "$f" \\
                  | grep -E -e '"type":"(user|assistant)"' \\
                  | grep -v -F -e '"tool_use_id"' -e '"type":"tool_use"' \\
                      -e '"isMeta":true' -e '"isSidechain":true' \\
                  | grep -i -E -e "$re" \\
                  | tail -n \(linesPerSession) \\
                  | sed -E 's/"data":"[A-Za-z0-9+\\/=]{64,}"/"data":""/g' \\
                  | head -c \(bytesPerSession)
                printf '\\n'
                break
              done
            done

            """.utf8)
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
        var sessionID: String?
        var latest: TranscriptSearchHit?
        func close() {
            if let latest { hits.append(latest) }
            latest = nil
        }
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix(sessionMarker) {
                close()
                sessionID = String(line.dropFirst(sessionMarker.count))
            } else if let sessionID, let hit = hit(in: line, sessionID: sessionID, needle: needle) {
                latest = hit
            }
        }
        close()
        return hits
    }

    private static func hit(
        in line: Substring, sessionID: String, needle: String
    ) -> TranscriptSearchHit? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            object["isMeta"] as? Bool != true,
            let role = role(of: object),
            let message = object["message"] as? [String: Any]
        else { return nil }
        for text in texts(in: message["content"]) {
            if let snippet = snippet(of: text, around: needle) {
                return TranscriptSearchHit(sessionID: sessionID, role: role, snippet: snippet)
            }
        }
        return nil
    }

    private static func role(of object: [String: Any]) -> TranscriptSearchHit.Role? {
        switch object["type"] as? String {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    /// The prose in a message: a plain string, or its text blocks.
    private static func texts(in content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }
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
