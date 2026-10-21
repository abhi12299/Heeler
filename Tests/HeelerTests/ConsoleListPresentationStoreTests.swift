import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console list presentation store")
struct ConsoleListPresentationStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-list-presentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: nil,
            repositoryCheckout: nil)
    }

    @Test func presentationModeDefaultsToFlatAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = ConsoleListPresentationStore(defaults: defaults)
        #expect(store.mode == .flat)

        store.select(.grouped)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .grouped)

        store.select(.flat)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .flat)
    }

    @Test func collapsedStatePersistsAndIsIsolatedPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: hostA.id)

        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        #expect(reloaded.isCollapsed(hostA.id))
        #expect(!reloaded.isCollapsed(hostB.id))

        reloaded.toggleCollapsed(hostB.id)
        reloaded.toggleCollapsed(hostA.id)
        let reloadedAgain = ConsoleListPresentationStore(defaults: defaults)
        #expect(!reloadedAgain.isCollapsed(hostA.id))
        #expect(reloadedAgain.isCollapsed(hostB.id))
    }

    @Test func sectionsFollowCatalogOrderAndFilterToAtMostOneHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let all = store.sections(hosts: [first, second], agents: [])
        #expect(all.map(\.hostID) == [first.id, second.id])

        let filtered = store.sections(
            hosts: [first, second], agents: [], filteredHostID: second.id)
        #expect(filtered.map(\.hostID) == [second.id])

        let missing = store.sections(
            hosts: [first, second], agents: [], filteredHostID: UUID())
        #expect(missing.isEmpty)
    }

    @Test func sectionsPreserveTheSuppliedAgentOrderWithinEachHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let aIdle = consoleAgent(host: hostA, paneID: "opaque-A", status: .idle)
        let bBlocked = consoleAgent(host: hostB, paneID: "%opaque-B", status: .blocked)
        let aDone = consoleAgent(host: hostA, paneID: "opaque-C", status: .done)
        let bWorking = consoleAgent(host: hostB, paneID: "opaque-D", status: .working)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [hostA, hostB],
            agents: [aIdle, bBlocked, aDone, bWorking])

        #expect(sections[0].agents.map(\.agent.paneID) == ["opaque-A", "opaque-C"])
        #expect(sections[1].agents.map(\.agent.paneID) == ["%opaque-B", "opaque-D"])
    }

    @Test func changedInputsReprojectMembershipAndReadiness() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "studio")
        let working = consoleAgent(host: host, paneID: "pane-1", status: .working)
        let done = consoleAgent(host: host, paneID: "pane-2", status: .done)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let loading = store.sections(
            hosts: [host],
            agents: [working],
            hostStatuses: [host.id: .connected],
            hostsAwaitingSnapshot: [host.id])
        #expect(loading[0].agents.map(\.id) == [working.id])
        #expect(loading[0].isAwaitingSnapshot)
        #expect(loading[0].statusPresentation?.message == "Loading Agents from studio…")

        let refreshed = store.sections(
            hosts: [host],
            agents: [done],
            hostStatuses: [host.id: .connected])
        #expect(refreshed[0].agents.map(\.id) == [done.id])
        #expect(!refreshed[0].isAwaitingSnapshot)
        #expect(refreshed[0].statusPresentation == nil)
    }

    @Test func emptyAndDisconnectedHostsRemainSections() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let empty = Host.fixture(name: "empty")
        let disconnected = Host.fixture(name: "offline")
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [empty, disconnected],
            agents: [],
            hostStatuses: [
                empty.id: .connected,
                disconnected.id: .failed(failure),
            ])

        #expect(sections.count == 2)
        #expect(sections[0].agents.isEmpty)
        #expect(sections[1].agents.isEmpty)
        #expect(sections[0].connectionStatus == .connected)
        #expect(sections[0].statusPresentation == nil)
        #expect(sections[1].connectionStatus == .failed(failure))
        #expect(sections[1].statusPresentation?.hostID == disconnected.id)
    }

    @Test func statusCountsMatchLiveActivityStatusesEvenWhenCollapsed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            consoleAgent(host: host, paneID: "blocked", status: .blocked),
            consoleAgent(host: host, paneID: "done", status: .done),
            consoleAgent(host: host, paneID: "working", status: .working),
            consoleAgent(host: host, paneID: "idle", status: .idle),
            consoleAgent(
                host: host, paneID: "unknown", status: AgentStatus(rawValue: "future")),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: host.id)

        let section = try #require(store.sections(hosts: [host], agents: agents).first)
        #expect(section.isCollapsed)
        #expect(section.statusCounts == .init(blocked: 1, working: 1, done: 1))
        #expect(section.statusCounts.items.map(\.status) == [.blocked, .working, .done])
    }
}

@Suite("Agent card presentation")
struct AgentCardPresentationTests {
    @Test func defaultsShowWorkspaceThenAgentWithoutTheOldDirectoryRow() {
        let card = AgentCardPresentation(agent: agent(workspace: "Project"))
        #expect(card.headline == "Project")
        #expect(card.additionalRows == ["reviewer"])
    }

    @Test func configuredTitlesAndPluginTextStayLiteralAndRetainStyles() throws {
        let layout = AgentRowLayout(rows: [
            [.init(.stateIcon), .init(.terminalTitleStripped, fg: HexColor("#abc"), bold: true)],
            [.init(.custom("note")), .init(.agent)],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "Task title")
        #expect(card.additionalRows == ["**literal** [link](url) · reviewer"])
        let first = try #require(card.rows.first?.first)
        #expect(first.fg == HexColor("#abc") && first.bold == true)
    }

    @Test func kindOverridesReplaceAllRowsAndSkipEmptyStatusRows() {
        let layout = AgentRowLayout(rows: [[.init(.workspace)]], rowsByAgent: [
            "claude": [[.init(.stateText)], [.init(.terminalTitle)], [.init(.custom("missing"))]],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "◑ Task title")
        #expect(card.additionalRows.isEmpty)
    }

    @Test func emptyLayoutsAndMissingValuesKeepAnIdentifiableAgent() {
        for layout in [AgentRowLayout(rows: []), AgentRowLayout(rows: [[], [.init(.custom("absent"))]])] {
            let card = AgentCardPresentation(agent: agent(), layout: layout)
            #expect(card.headline == "reviewer")
            #expect(card.additionalRows.isEmpty)
        }
        #expect(AgentCardPresentation(agent: agent()).headline == "reviewer")
    }

    private func agent(workspace: String? = nil) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "terminal", kind: "claude", title: "Old title", status: .blocked,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/project", revision: 1,
                name: "reviewer", terminalTitle: "◑ Task title", terminalTitleStripped: "Task title",
                tokens: ["note": "**literal** [link](url)"]),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }
}

@MainActor
@Suite("Console list By Workspace")
struct ConsoleWorkspaceSectionsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-list-workspaces-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        host: Host, paneID: String, workspaceID: String, label: String? = nil,
        status: AgentStatus = .idle, title: String = "Task"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                .fixture(paneID: paneID, status: status, workspaceID: workspaceID, title: title)),
            workspaceLabel: label,
            repositoryCheckout: nil)
    }

    @Test func sectionsFollowHerdrWorkspaceOrderAndKeepConsoleAgentOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "devbox")
        let store = ConsoleListPresentationStore(defaults: defaults)
        let a = consoleAgent(host: host, paneID: "a", workspaceID: "w2")
        let b = consoleAgent(host: host, paneID: "b", workspaceID: "w1")
        let c = consoleAgent(host: host, paneID: "c", workspaceID: "w2")

        let sections = store.workspaceSections(
            hosts: [host],
            agents: [a, b, c],
            workspacesByHost: [
                host.id: [
                    ConsoleWorkspace(id: "w3", label: "docs", order: 2),
                    ConsoleWorkspace(id: "w1", label: "api", order: 0),
                    ConsoleWorkspace(id: "w2", label: "web", order: 1),
                ]
            ])

        #expect(sections.map(\.title) == ["api", "web", "docs"])
        #expect(sections.map { $0.agents.map(\.agent.paneID) } == [["b"], ["a", "c"], []])
        #expect(sections.allSatisfy { $0.hostID == host.id && $0.hostName == "devbox" })
    }

    @Test func agentOutrunningItsWorkspaceStaysListedUnderItsOwnWorkspace() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "devbox")
        let store = ConsoleListPresentationStore(defaults: defaults)
        let known = consoleAgent(host: host, paneID: "a", workspaceID: "w1")
        let labelled = consoleAgent(host: host, paneID: "b", workspaceID: "w9", label: "late")
        let unlabelled = consoleAgent(host: host, paneID: "c", workspaceID: "w7", label: "  ")

        let sections = store.workspaceSections(
            hosts: [host],
            agents: [unlabelled, labelled, known],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: " ", order: 0)]])

        #expect(sections.map(\.title) == ["Workspace w1", "Workspace w7", "late"])
        #expect(sections.map { $0.agents.map(\.agent.paneID) } == [["a"], ["c"], ["b"]])
    }

    @Test func hostFilterAndSearchNarrowWorkspacesAsTheTerminalsListDoes() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)
        let match = consoleAgent(host: first, paneID: "a", workspaceID: "w1", title: "deploy fix")
        let other = consoleAgent(host: first, paneID: "b", workspaceID: "w1", title: "refactor")
        let elsewhere = consoleAgent(host: second, paneID: "c", workspaceID: "w1")
        let workspaces: [Host.ID: [ConsoleWorkspace]] = [
            first.id: [
                ConsoleWorkspace(id: "w1", label: "api", order: 0),
                ConsoleWorkspace(id: "w2", label: "idle", order: 1),
            ],
            second.id: [ConsoleWorkspace(id: "w1", label: "web", order: 0)],
        ]
        let agents = [match, other, elsewhere]

        let all = store.workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: workspaces)
        #expect(all.map(\.title) == ["api", "idle", "web"])

        let filtered = store.workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: workspaces,
            filteredHostID: second.id)
        #expect(filtered.map(\.title) == ["web"])

        // A query keeps matching Agents only and drops Workspaces left empty.
        let searched = store.workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: workspaces,
            searchQuery: " deploy ")
        #expect(searched.map(\.title) == ["api"])
        #expect(searched.first?.agents.map(\.agent.paneID) == ["a"])
    }

    @Test func collapsedWorkspacesPersistPerHostAndASearchOpensThem() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        // A slash in an opaque Workspace id must survive the round trip.
        let collapsed = ConsoleWorkspaceSection.ID(hostID: first.id, workspaceID: "w/1")
        let agents = [
            consoleAgent(host: first, paneID: "a", workspaceID: "w/1"),
            consoleAgent(host: second, paneID: "b", workspaceID: "w/1"),
        ]

        ConsoleListPresentationStore(defaults: defaults).toggleCollapsed(collapsed)
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        let sections = reloaded.workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: [:])
        #expect(sections.map(\.isCollapsed) == [true, false])

        let searched = reloaded.workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: [:], searchQuery: "Task")
        #expect(searched.map(\.isCollapsed) == [false, false])

        reloaded.toggleCollapsed(collapsed)
        let reopened = ConsoleListPresentationStore(defaults: defaults).workspaceSections(
            hosts: [first, second], agents: agents, workspacesByHost: [:])
        #expect(reopened.map(\.isCollapsed) == [false, false])
    }

    @Test func byWorkspacePersistsAndListsHostProblemsAboveItsSections() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        ConsoleListPresentationStore(defaults: defaults).select(.byWorkspace)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .byWorkspace)
        #expect(ConsoleListPresentationMode.byWorkspace.title == "By Workspace")
        // No Host headers carry their problems, so they lead the list.
        #expect(ConsoleHostIssuePlacement(mode: .byWorkspace) == .flatIssueRows)
    }

    @Test func byWorkspaceSurfaceShowsSectionsEvenWithoutAgents() {
        func surface(
            sections: Int, issues: Int = 0, host: String? = nil, query: String = ""
        ) -> ConsoleAgentsSurface {
            ConsoleAgentsSurface(
                hostCount: 1, filteredHostName: host, filteredAgentCount: 0,
                visibleIssueCount: issues, presentationMode: .byWorkspace,
                projectedSectionCount: sections, searchQuery: query)
        }
        // An empty Workspace still offers New Agent.
        #expect(surface(sections: 1) == .rows)
        #expect(surface(sections: 0, issues: 1) == .rows)
        #expect(surface(sections: 0) == .noAgents)
        #expect(surface(sections: 0, host: "devbox") == .noAgentsOnHost("devbox"))
        #expect(surface(sections: 0, query: "x") == .noSearchResults)
    }

    @Test func aTranscriptMatchKeepsItsAgentInEveryPresentation() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "devbox")
        let store = ConsoleListPresentationStore(defaults: defaults)
        let byName = consoleAgent(host: host, paneID: "a", workspaceID: "w1", title: "relay fix")
        let byTranscript = consoleAgent(host: host, paneID: "b", workspaceID: "w2")
        let neither = consoleAgent(host: host, paneID: "c", workspaceID: "w2")
        let agents = [byName, byTranscript, neither]
        let transcriptMatches: Set<ConsoleAgent.ID> = [byTranscript.id]

        #expect(
            agents.filter { $0.matchesListSearch("relay", transcriptMatches: transcriptMatches) }
                .map(\.agent.paneID) == ["a", "b"])
        let hostSections = store.sections(
            hosts: [host], agents: agents, searchQuery: "relay",
            transcriptMatches: transcriptMatches)
        #expect(hostSections.first?.agents.map(\.agent.paneID) == ["a", "b"])
        let workspaceSections = store.workspaceSections(
            hosts: [host], agents: agents, workspacesByHost: [:], searchQuery: "relay",
            transcriptMatches: transcriptMatches)
        #expect(workspaceSections.map { $0.agents.map(\.agent.paneID) } == [["a"], ["b"]])
    }

    @Test(arguments: ConsoleListPresentationMode.allCases)
    func pendingTranscriptsReplaceNoResultsWithSearching(mode: ConsoleListPresentationMode) {
        func surface(awaiting: Bool) -> ConsoleAgentsSurface {
            ConsoleAgentsSurface(
                hostCount: 1, filteredHostName: nil, filteredAgentCount: 0,
                visibleIssueCount: 0, presentationMode: mode, projectedSectionCount: 0,
                searchQuery: "relay", isAwaitingTranscripts: awaiting)
        }
        #expect(surface(awaiting: true) == .searchingTranscripts)
        #expect(surface(awaiting: false) == .noSearchResults)
    }

    @Test func aWorkspaceSectionRowShowsTheAgentsNameAndPathOnly() {
        let host = Host.fixture(name: "Mac")
        let agent = ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                .fixture(
                    paneID: "a", workspaceID: "w1", title: "Fix parser",
                    name: "all-257-parser-fix")),
            workspaceLabel: "allied",
            repositoryCheckout: nil,
            tabLabel: "parser")

        // The section header already names the Workspace and its Host.
        let card = AgentCardPresentation(agent: agent, layout: .workspaceSection)
        #expect(card.headline == "all-257-parser-fix")
        #expect(card.additionalRows == ["/work/w1"])
    }
}
