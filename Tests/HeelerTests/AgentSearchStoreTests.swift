import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("agent search store")
struct AgentSearchStoreTests {
    private static let mac = UUID()
    private static let linux = UUID()

    private static func agent(
        _ pane: String,
        host: UUID = mac,
        name: String? = nil,
        kind: String = "claude",
        session: String? = nil,
        sessionKind: AgentSessionRefKind = .id
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: host == mac ? "mac" : "linux",
            agent: Agent(
                terminalID: "term-\(pane)", kind: kind, title: "", status: .idle,
                workspaceID: String(pane.prefix(2)), tabID: "\(pane):t", paneID: pane,
                cwd: "/srv/app", revision: 0, name: name,
                agentSession: session.map {
                    AgentSessionInfo(agent: kind, kind: sessionKind, source: "herdr:\(kind)", value: $0)
                }),
            workspaceLabel: nil,
            repositoryCheckout: nil)
    }

    /// Records what each Host was asked and answers from a script.
    private final class Hosts: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [UUID: [TranscriptSearchRequest]] = [:]
        private var answers: [UUID: Result<[TranscriptSearchHit], TransportError>] = [:]

        func answer(_ host: UUID, _ result: Result<[TranscriptSearchHit], TransportError>) {
            lock.withLock { answers[host] = result }
        }

        func requests(_ host: UUID) -> [TranscriptSearchRequest] {
            lock.withLock { asked[host] ?? [] }
        }

        func search(_ host: UUID, _ request: TranscriptSearchRequest) throws -> [TranscriptSearchHit] {
            try lock.withLock {
                asked[host, default: []].append(request)
                return try (answers[host] ?? .success([])).get()
            }
        }
    }

    @MainActor
    private final class Typing {
        weak var store: AgentSearchStore?
        func type(_ query: String) { store?.query = query }
    }

    private static func hit(_ session: String, _ snippet: String) -> TranscriptSearchHit {
        TranscriptSearchHit(sessionID: session, role: .assistant, snippet: snippet)
    }

    private static func store(_ agents: [ConsoleAgent], _ hosts: Hosts) -> AgentSearchStore {
        AgentSearchStore(agents: { agents }) { host, request in
            try hosts.search(host, request)
        }
    }

    @Test func anEmptyQueryListsEveryRunningAgentAcrossWorkspaces() async {
        let hosts = Hosts()
        let store = Self.store(
            [Self.agent("w1:p1"), Self.agent("w2:p1"), Self.agent("w9:p1", host: Self.linux)], hosts)

        await store.search()

        #expect(store.rows.map(\.agent.agent.paneID) == ["w1:p1", "w2:p1", "w9:p1"])
        #expect(store.rows.allSatisfy { $0.snippet == nil })
        #expect(hosts.requests(Self.mac).isEmpty)
    }

    @Test func aTranscriptHitKeepsItsAgentAndShowsTheSnippet() async {
        let hosts = Hosts()
        hosts.answer(Self.mac, .success([Self.hit("s-2", "the relay restarted")]))
        let store = Self.store(
            [Self.agent("w1:p1", session: "s-1"), Self.agent("w2:p1", session: "s-2")], hosts)

        store.query = " relay "
        await store.search()

        #expect(store.rows.map(\.agent.agent.paneID) == ["w2:p1"])
        #expect(store.rows.first?.snippet == "the relay restarted")
        #expect(hosts.requests(Self.mac) == [
            TranscriptSearchRequest(query: "relay", sessions: [
                TranscriptSession(source: .claude, id: "s-1"),
                TranscriptSession(source: .claude, id: "s-2"),
            ])
        ])
    }

    /// The name filter needs no Host, so it applies before any answer.
    @Test func anAgentWhoseNameMatchesIsListedWithoutATranscriptHit() async {
        let hosts = Hosts()
        let store = Self.store(
            [Self.agent("w1:p1", name: "relay-fix", session: "s-1"), Self.agent("w2:p1", session: "s-2")],
            hosts)

        store.query = "relay"

        #expect(store.rows.map(\.agent.agent.paneID) == ["w1:p1"])
        #expect(store.rows.first?.snippet == nil)
    }

    /// A session id names a transcript only for the kinds this search can
    /// read; a Host with none is not asked at all.
    @Test func eachHostIsAskedOnlyForTheSessionsItCanRead() async {
        let hosts = Hosts()
        let store = Self.store(
            [
                Self.agent("w1:p1", session: "s-1"),
                Self.agent("w1:p2", kind: "codex", session: "s-codex"),
                Self.agent("w1:p3", kind: "omp", session: "/tmp/s.jsonl", sessionKind: .path),
                Self.agent("w1:p4"),
                Self.agent("w9:p1", host: Self.linux, kind: "gemini", session: "s-other"),
            ], hosts)

        store.query = "relay"
        await store.search()

        #expect(hosts.requests(Self.mac).map(\.sessions) == [[
            TranscriptSession(source: .claude, id: "s-1"),
            TranscriptSession(source: .codex, id: "s-codex"),
        ]])
        #expect(hosts.requests(Self.linux).isEmpty)
    }

    @Test func aCodexTranscriptHitKeepsItsAgent() async {
        let hosts = Hosts()
        hosts.answer(Self.mac, .success([Self.hit("s-codex", "the relay restarted")]))
        let store = Self.store(
            [Self.agent("w1:p1", session: "s-1"), Self.agent("w1:p2", kind: "codex", session: "s-codex")],
            hosts)

        store.query = "relay"
        await store.search()

        #expect(store.rows.map(\.agent.agent.paneID) == ["w1:p2"])
        #expect(store.rows.first?.snippet == "the relay restarted")
    }

    @Test func anAnswerForAnOlderQueryIsDropped() async {
        let hosts = Hosts()
        hosts.answer(Self.mac, .success([Self.hit("s-1", "the relay restarted")]))
        let agents = [Self.agent("w1:p1", session: "s-1")]
        // The user types on while the Host is still answering.
        let typing = Typing()
        let store = AgentSearchStore(agents: { agents }) { host, request in
            await typing.type("tunnel")
            return try hosts.search(host, request)
        }
        typing.store = store

        store.query = "relay"
        await store.search()

        #expect(store.rows.isEmpty)
    }

    @Test func aHostThatFailsIsReportedWhileTheOthersStillAnswer() async {
        let hosts = Hosts()
        hosts.answer(Self.mac, .failure(.timedOut))
        hosts.answer(Self.linux, .success([Self.hit("s-9", "relay is fine here")]))
        let store = Self.store(
            [Self.agent("w1:p1", session: "s-1"), Self.agent("w9:p1", host: Self.linux, session: "s-9")],
            hosts)

        store.query = "relay"
        await store.search()

        #expect(store.rows.map(\.agent.agent.paneID) == ["w9:p1"])
        #expect(store.searchFailed)
        #expect(!store.isSearching)
    }
}
