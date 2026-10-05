import Foundation
import Testing

@testable import Heeler

@Suite("transcript search probe")
struct TranscriptSearchProbeTests {
    private static let first = "11111111-aaaa-4bbb-8ccc-000000000001"
    private static let second = "22222222-aaaa-4bbb-8ccc-000000000002"

    private static func userLine(_ text: String, timestamp: String = "2026-10-05T09:00:00.000Z") -> String {
        line(type: "user", content: text, timestamp: timestamp)
    }

    private static func assistantLine(
        _ text: String, timestamp: String = "2026-10-05T09:00:00.000Z"
    ) -> String {
        line(type: "assistant", content: [["type": "text", "text": text]], timestamp: timestamp)
    }

    private static func line(type: String, content: Any, timestamp: String) -> String {
        let object: [String: Any] = [
            "type": type,
            "timestamp": timestamp,
            "cwd": "/srv/relay",
            "message": ["role": type, "content": content],
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    private static func output(_ sections: [(String, [String])]) -> Data {
        var text = ""
        for (session, lines) in sections {
            text += "@@heeler-session \(session)\n"
            text += lines.map { $0 + "\n" }.joined()
            text += "\n"
        }
        return Data(text.utf8)
    }

    @Test func aMatchingMessageBecomesAHitForItsSession() {
        let output = Self.output([
            (Self.first, [Self.userLine("please wire up the push relay today")]),
            (Self.second, []),
        ])

        let hits = TranscriptSearchProbe.hits(fromOutput: output, query: "Push Relay")

        #expect(hits.map(\.sessionID) == [Self.first])
        #expect(hits.first?.role == .user)
        #expect(hits.first?.snippet == "please wire up the push relay today")
    }

    @Test func theLatestMatchingMessageSpeaksForTheSession() {
        let output = Self.output([
            (Self.first, [
                Self.userLine("is the relay up?"),
                Self.assistantLine("The relay answered on the second try."),
            ]),
        ])

        let hits = TranscriptSearchProbe.hits(fromOutput: output, query: "relay")

        #expect(hits.count == 1)
        #expect(hits.first?.role == .assistant)
        #expect(hits.first?.snippet == "The relay answered on the second try.")
    }

    /// The Host's filter is coarse; only text the user or the Agent wrote
    /// counts, so a directory name or a tool's output is never a hit.
    @Test func textNobodyWroteIsNotAHit() {
        let toolResult = Self.line(
            type: "user",
            content: [["type": "tool_result", "tool_use_id": "toolu_1", "content": "relay.js"]],
            timestamp: "2026-10-05T09:00:00.000Z")
        let output = Self.output([
            (Self.first, [
                Self.userLine("what is in this directory?"),
                toolResult,
                "{\"type\":\"user\",\"message\":{\"content\":\"relay cut off mid-li",
            ]),
        ])

        #expect(TranscriptSearchProbe.hits(fromOutput: output, query: "relay").isEmpty)
    }

    private static func script(_ query: String, _ sessionIDs: [String]) -> String? {
        TranscriptSearchProbe.script(
            for: TranscriptSearchRequest(query: query, sessionIDs: sessionIDs)
        ).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Only the running Agents' own files are opened: each is found by its
    /// file name, and no command is handed the projects folder to walk.
    @Test func theScriptOpensOnlyTheNamedSessionFiles() throws {
        let script = try #require(Self.script("relay", [Self.first, Self.second]))

        #expect(script.contains("for id in \(Self.first) \(Self.second); do"))
        #expect(script.contains("/projects/*/\"$id\".jsonl"))
        #expect(!script.contains("grep -r"))
        #expect(!script.contains("find "))
    }

    @Test func aSessionIDThatIsNotAPlainTokenNeverReachesTheShell() throws {
        let script = try #require(Self.script("relay", ["x; rm -rf ~", "$(id)", "../../etc", Self.first]))

        #expect(script.contains("for id in \(Self.first); do"))
        #expect(!script.contains("rm -rf"))
        #expect(!script.contains("$(id)"))
        #expect(!script.contains("etc"))
    }

    @Test func nothingToSearchMeansNoScript() {
        #expect(Self.script("  \n", [Self.first]) == nil)
        #expect(Self.script("relay", []) == nil)
        #expect(Self.script("relay", ["not a token"]) == nil)
    }

    /// The query is data on both sides: quoted for the shell, and escaped as
    /// the transcript stores it (JSON) before it becomes a pattern.
    @Test func theQueryIsQuotedForTheShellAndThePattern() throws {
        let script = try #require(Self.script("it's \"a.b\" (x)", [Self.first]))

        #expect(script.contains(#"q='it'\''s \"a.b\" (x)'"#))
        #expect(script.contains(#"it'\''s \\"a\.b\\" \(x\)'"#))
    }

    @Test func aLongMessageIsCutToTheWordsAroundTheMatch() {
        let before = String(repeating: "alpha ", count: 40)
        let after = String(repeating: " omega", count: 60)
        let output = Self.output([
            (Self.first, [Self.assistantLine("\(before)the\nRELAY   restarted\(after)")]),
        ])

        let snippet = TranscriptSearchProbe.hits(fromOutput: output, query: "relay").first?.snippet

        #expect(snippet?.hasPrefix("…") == true)
        #expect(snippet?.hasSuffix("…") == true)
        #expect(snippet?.contains("the RELAY restarted") == true)
        #expect((snippet?.count ?? 0) <= TranscriptSearchProbe.snippetLength + 2)
    }
}
