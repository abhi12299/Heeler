import Foundation
import Observation

/// The Agent search panel's list: every running Agent across Workspaces and
/// Hosts, narrowed by a query that is matched against what an Agent row shows
/// and against the Agents' own session transcripts.
///
/// Only the transcripts of Agents running now are searched, named by the
/// session ids herdr reports. One request goes to each Host that has any.
@MainActor
@Observable
final class AgentSearchStore {
    typealias Search = @Sendable (Host.ID, TranscriptSearchRequest) async throws -> [TranscriptSearchHit]
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How long typing rests before the Hosts are asked: each search reads
    /// every running Agent's transcript over SSH, so not on every keystroke.
    static let typingSettleDelay: Duration = .seconds(1)

    struct Row: Identifiable, Equatable {
        let agent: ConsoleAgent
        /// The transcript text around the match; nil for an Agent listed by
        /// its name alone, or while no query is entered.
        let snippet: String?
        let role: TranscriptSearchHit.Role?

        var id: ConsoleAgent.ID { agent.id }
    }

    private struct SessionKey: Hashable {
        let hostID: Host.ID
        let sessionID: String
    }

    var query = ""
    private(set) var isSearching = false
    /// A Host did not answer the last search; the rows show what the others
    /// and the name filter found.
    private(set) var searchFailed = false

    @ObservationIgnored private let agents: () -> [ConsoleAgent]
    @ObservationIgnored private let search: Search
    @ObservationIgnored private let sleep: Sleep
    /// Hits for `hitsQuery` only; a newer query hides them until its own
    /// answer lands.
    private var hits: [SessionKey: TranscriptSearchHit] = [:]
    private var hitsQuery = ""

    init(
        agents: @escaping () -> [ConsoleAgent], search: @escaping Search,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.agents = agents
        self.search = search
        self.sleep = sleep
    }

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var rows: [Row] {
        let needle = needle
        guard !needle.isEmpty else {
            return agents().map { Row(agent: $0, snippet: nil, role: nil) }
        }
        let current = hitsQuery == needle ? hits : [:]
        return agents().compactMap { agent in
            if let key = sessionKey(for: agent), let hit = current[key] {
                return Row(agent: agent, snippet: hit.snippet, role: hit.role)
            }
            return agent.matchesAgentSearch(needle) ? Row(agent: agent, snippet: nil, role: nil) : nil
        }
    }

    /// The current query's transcripts are still out: waiting for typing to
    /// rest, or for the Hosts to answer. A list should not yet claim it has
    /// found nothing.
    var isAwaitingTranscripts: Bool {
        let needle = needle
        return !needle.isEmpty && hitsQuery != needle
    }

    /// The transcript hit behind each Agent the current query found in its
    /// transcript, for a list that keeps its own name matching. Empty until
    /// the current query's answer lands.
    var transcriptHits: [ConsoleAgent.ID: TranscriptSearchHit] {
        let needle = needle
        guard !needle.isEmpty, hitsQuery == needle else { return [:] }
        var found: [ConsoleAgent.ID: TranscriptSearchHit] = [:]
        for agent in agents() {
            if let key = sessionKey(for: agent), let hit = hits[key] { found[agent.id] = hit }
        }
        return found
    }

    private func sessionKey(for agent: ConsoleAgent) -> SessionKey? {
        agent.transcriptSession.map { SessionKey(hostID: agent.hostID, sessionID: $0.id) }
    }

    /// Searches once typing has rested for `typingSettleDelay`. Run it per
    /// query change: a newer keystroke cancels the wait, and with it this
    /// search.
    func searchAfterTypingSettles() async {
        do {
            try await sleep(Self.typingSettleDelay)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        await search()
    }

    /// Asks each Host for the current query. An answer that arrives after the
    /// query has changed is dropped.
    func search() async {
        let needle = needle
        guard !needle.isEmpty else {
            hits = [:]
            hitsQuery = ""
            searchFailed = false
            isSearching = false
            return
        }
        var sessions: [(hostID: Host.ID, sessions: [TranscriptSession])] = []
        for agent in agents() {
            guard let session = agent.transcriptSession else { continue }
            if let index = sessions.firstIndex(where: { $0.hostID == agent.hostID }) {
                sessions[index].sessions.append(session)
            } else {
                sessions.append((agent.hostID, [session]))
            }
        }
        isSearching = true
        let search = search
        let answers = await withTaskGroup(
            of: (Host.ID, [TranscriptSearchHit]?).self
        ) { group in
            for (hostID, sessions) in sessions {
                group.addTask {
                    let request = TranscriptSearchRequest(query: needle, sessions: sessions)
                    return (hostID, try? await search(hostID, request))
                }
            }
            var answers: [(Host.ID, [TranscriptSearchHit]?)] = []
            for await answer in group { answers.append(answer) }
            return answers
        }
        guard needle == self.needle else { return }
        isSearching = false
        guard !Task.isCancelled else { return }
        var found: [SessionKey: TranscriptSearchHit] = [:]
        for (hostID, hostHits) in answers {
            for hit in hostHits ?? [] {
                found[SessionKey(hostID: hostID, sessionID: hit.sessionID)] = hit
            }
        }
        hits = found
        hitsQuery = needle
        searchFailed = answers.contains { $0.1 == nil }
    }
}
