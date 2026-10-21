import Foundation
import Observation

/// The Console Agent-list presentations. Flat remains the default so
/// introducing grouped-list support does not change the existing surface
/// until the UI explicitly selects it. By Workspace nests Agents under one
/// collapsible section per Workspace, as the Terminals tab's By Workspace
/// does.
enum ConsoleListPresentationMode: String, CaseIterable, Identifiable, Sendable {
    case flat
    case grouped
    case byWorkspace

    var id: Self { self }

    /// Toolbar / picker label for the presentation switcher.
    var title: String {
        switch self {
        case .flat: "All Agents"
        case .grouped: "By Host"
        case .byWorkspace: "By Workspace"
        }
    }

    /// Beside the title in the picker, and alone on the toolbar button so
    /// it shows the current choice.
    var systemImage: String {
        switch self {
        case .flat: "list.bullet"
        case .grouped: "list.bullet.indent"
        case .byWorkspace: "rectangle.3.group"
        }
    }
}

/// One Host section projected from the Host catalog and the Console's
/// already-sorted Agent sequence. The section carries the inputs a header
/// needs to present connection and Agent Inventory readiness honestly.
struct ConsoleHostSection: Identifiable, Equatable {
    let hostID: Host.ID
    let hostDisplayName: String
    let connectionStatus: EventsSessionStatus?
    let isAwaitingSnapshot: Bool
    let statusPresentation: ConsoleHostStatusPresentation?
    let agents: [ConsoleAgent]
    let isCollapsed: Bool
    let statusCounts: ConsoleHostAgentStatusCounts

    var id: Host.ID { hostID }
}

/// One Workspace section of the By Workspace presentation: the Workspace's
/// Agents in the Console's own order. Workspace ids are opaque and scoped to
/// their Host, so the pair is the section's identity.
struct ConsoleWorkspaceSection: Identifiable, Equatable {
    struct ID: Hashable, Sendable {
        let hostID: Host.ID
        let workspaceID: String
    }

    let hostID: Host.ID
    let hostName: String
    let workspaceID: String
    let title: String
    let agents: [ConsoleAgent]
    let isCollapsed: Bool

    var id: ID { ID(hostID: hostID, workspaceID: workspaceID) }

    /// What VoiceOver hears for the section's header.
    var headerAccessibilityValue: String {
        let count = agents.count == 1 ? "1 agent" : "\(agents.count) agents"
        return "\(count), \(isCollapsed ? "Collapsed" : "Expanded")"
    }
}

/// The Live Activity-eligible Agent statuses shown in a collapsed Host
/// section. Keeping the same order and labels as the Live Activity makes the
/// two summaries directly comparable.
struct ConsoleHostAgentStatusCounts: Equatable {
    let blocked: Int
    let working: Int
    let done: Int

    init(blocked: Int = 0, working: Int = 0, done: Int = 0) {
        self.blocked = blocked
        self.working = working
        self.done = done
    }

    init(agents: [ConsoleAgent]) {
        blocked = agents.count { $0.agent.status == .blocked }
        working = agents.count { $0.agent.status == .working }
        done = agents.count { $0.agent.status == .done }
    }

    var items: [ConsoleHostAgentStatusCount] {
        var items: [ConsoleHostAgentStatusCount] = []
        if blocked > 0 { items.append(.init(status: .blocked, count: blocked)) }
        if working > 0 { items.append(.init(status: .working, count: working)) }
        if done > 0 { items.append(.init(status: .done, count: done)) }
        return items
    }
}

struct ConsoleHostAgentStatusCount: Identifiable, Equatable {
    let status: AgentStatus
    let count: Int

    var id: String { status.rawValue }
}

/// Persists the Console presentation choice and per-Host and per-Workspace
/// collapsed state, and projects grouped sections without taking ownership
/// of Agent sorting. Collapsed ids are deliberately retained when a Host
/// disconnects or leaves the catalog so a reconnect or later return restores
/// the choice.
@MainActor
@Observable
final class ConsoleListPresentationStore {
    private static let modeDefaultsKey = "console-list.presentation-mode"
    private static let collapsedHostsDefaultsKey = "console-list.collapsed-hosts"
    private static let collapsedWorkspacesDefaultsKey = "console-list.collapsed-workspaces"

    private(set) var mode: ConsoleListPresentationMode
    private var collapsedHostIDs: Set<Host.ID>
    private var collapsedWorkspaceIDs: Set<ConsoleWorkspaceSection.ID>
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode =
            defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(ConsoleListPresentationMode.init(rawValue:)) ?? .flat
        collapsedHostIDs = Set(
            (defaults.stringArray(forKey: Self.collapsedHostsDefaultsKey) ?? [])
                .compactMap(UUID.init(uuidString:)))
        collapsedWorkspaceIDs = Set(
            (defaults.stringArray(forKey: Self.collapsedWorkspacesDefaultsKey) ?? [])
                .compactMap(Self.workspaceID(from:)))
    }

    func select(_ mode: ConsoleListPresentationMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
    }

    func isCollapsed(_ hostID: Host.ID) -> Bool {
        collapsedHostIDs.contains(hostID)
    }

    func setCollapsed(_ collapsed: Bool, for hostID: Host.ID) {
        let changed: Bool
        if collapsed {
            changed = collapsedHostIDs.insert(hostID).inserted
        } else {
            changed = collapsedHostIDs.remove(hostID) != nil
        }
        guard changed else { return }
        persistCollapsedHostIDs()
    }

    func toggleCollapsed(_ hostID: Host.ID) {
        setCollapsed(!isCollapsed(hostID), for: hostID)
    }

    func toggleCollapsed(_ id: ConsoleWorkspaceSection.ID) {
        if collapsedWorkspaceIDs.remove(id) == nil { collapsedWorkspaceIDs.insert(id) }
        defaults.set(
            collapsedWorkspaceIDs.map(Self.key(for:)).sorted(),
            forKey: Self.collapsedWorkspacesDefaultsKey)
    }

    /// Convenience contract for the Console UI. Reading these observable
    /// inputs on each render makes status, inventory, and membership changes
    /// re-project without a second cache to reconcile.
    func sections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = "",
        transcriptMatches: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleHostSection] {
        sections(
            hosts: hosts,
            agents: console.agents,
            hostStatuses: console.hostStatuses,
            hostStandingFailures: console.hostStandingFailures,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostSyncErrors: console.hostSyncErrors,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery,
            transcriptMatches: transcriptMatches)
    }

    /// Projects one section per catalog Host, in catalog order. `agents` is
    /// already sorted by ConsoleStore; filtering it in-place keeps
    /// that exact relative order within every Host section.
    func sections(
        hosts: [Host],
        agents: [ConsoleAgent],
        hostStatuses: [Host.ID: EventsSessionStatus] = [:],
        hostStandingFailures: [Host.ID: TransportError] = [:],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostSyncErrors: [Host.ID: String] = [:],
        filteredHostID: Host.ID? = nil,
        searchQuery: String = "",
        transcriptMatches: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleHostSection] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchedAgents =
            trimmedQuery.isEmpty
            ? agents
            : agents.filter {
                $0.matchesListSearch(trimmedQuery, transcriptMatches: transcriptMatches)
            }
        let agentsByHost = Dictionary(grouping: searchedAgents, by: \.hostID)
        var projectedHostIDs: Set<Host.ID> = []

        return hosts.compactMap { host in
            guard filteredHostID == nil || host.id == filteredHostID else { return nil }
            guard projectedHostIDs.insert(host.id).inserted else { return nil }

            let hostAgents = agentsByHost[host.id] ?? []
            let isAwaitingSnapshot = hostsAwaitingSnapshot.contains(host.id)
            let statusPresentation = ConsoleHostStatusPresentation(
                host: host,
                status: hostStatuses[host.id],
                standingFailure: hostStandingFailures[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                syncError: hostSyncErrors[host.id])
            // While searching, a section without a match leaves the list
            // whatever its Host's state (#292, #316): a query asks for Agents,
            // and Hosts that cannot answer only bury the matches. Without a
            // query every catalog Host stays visible, including empty ones.
            if !trimmedQuery.isEmpty && hostAgents.isEmpty { return nil }
            return ConsoleHostSection(
                hostID: host.id,
                hostDisplayName: host.displayName,
                connectionStatus: hostStatuses[host.id],
                isAwaitingSnapshot: isAwaitingSnapshot,
                statusPresentation: statusPresentation,
                agents: hostAgents,
                // A match is never hidden behind a collapsed Host.
                isCollapsed: trimmedQuery.isEmpty && isCollapsed(host.id),
                statusCounts: ConsoleHostAgentStatusCounts(agents: hostAgents))
        }
    }

    /// Convenience contract for the Console UI, as `sections(hosts:console:)`.
    func workspaceSections(
        hosts: [Host],
        console: ConsoleStore,
        filteredHostID: Host.ID? = nil,
        searchQuery: String = "",
        transcriptMatches: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleWorkspaceSection] {
        workspaceSections(
            hosts: hosts,
            agents: console.agents,
            workspacesByHost: console.workspacesByHost,
            filteredHostID: filteredHostID,
            searchQuery: searchQuery,
            transcriptMatches: transcriptMatches)
    }

    /// Projects one section per Workspace: Host catalog order first, then
    /// herdr's Workspace order. `agents` is already sorted by ConsoleStore,
    /// so each section keeps that relative order. As in the Terminals list, a
    /// query keeps matching Agents only and drops Workspaces left empty;
    /// without one, a Workspace running no Agents stays listed.
    func workspaceSections(
        hosts: [Host],
        agents: [ConsoleAgent],
        workspacesByHost: [Host.ID: [ConsoleWorkspace]],
        filteredHostID: Host.ID? = nil,
        searchQuery: String = "",
        transcriptMatches: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleWorkspaceSection] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var projectedHostIDs: Set<Host.ID> = []
        let visibleHosts = hosts.filter {
            (filteredHostID == nil || $0.id == filteredHostID)
                && projectedHostIDs.insert($0.id).inserted
        }
        return visibleHosts.flatMap { host in
            let hostAgents = agents.filter {
                $0.hostID == host.id
                    && (trimmedQuery.isEmpty
                        || $0.matchesListSearch(trimmedQuery, transcriptMatches: transcriptMatches))
            }
            let agentsByWorkspace = Dictionary(grouping: hostAgents, by: \.agent.workspaceID)
            let known = (workspacesByHost[host.id] ?? []).sorted { $0.order < $1.order }
            // A pane can outrun its Workspace between snapshots; keep it listed
            // under its own id rather than dropping a live Agent.
            var ordered: [(id: String, label: String?)] = known.map { ($0.id, $0.label) }
            for agent in hostAgents where !ordered.contains(where: { $0.id == agent.agent.workspaceID }) {
                ordered.append((agent.agent.workspaceID, agent.workspaceLabel))
            }
            return ordered.compactMap { id, label -> ConsoleWorkspaceSection? in
                let sectionAgents = agentsByWorkspace[id] ?? []
                if !trimmedQuery.isEmpty && sectionAgents.isEmpty { return nil }
                let title = label?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ConsoleWorkspaceSection(
                    hostID: host.id,
                    hostName: host.displayName,
                    workspaceID: id,
                    title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Workspace \(id)",
                    agents: sectionAgents,
                    // A match is never hidden behind a collapsed Workspace.
                    isCollapsed: trimmedQuery.isEmpty
                        && collapsedWorkspaceIDs.contains(
                            ConsoleWorkspaceSection.ID(hostID: host.id, workspaceID: id)))
            }
        }
    }

    private func persistCollapsedHostIDs() {
        defaults.set(
            collapsedHostIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedHostsDefaultsKey)
    }

    /// Host UUID first: it never contains the separator, so everything after
    /// the first one is the opaque Workspace id, whatever it contains.
    private static func key(for id: ConsoleWorkspaceSection.ID) -> String {
        "\(id.hostID.uuidString)/\(id.workspaceID)"
    }

    private static func workspaceID(from key: String) -> ConsoleWorkspaceSection.ID? {
        guard let separator = key.firstIndex(of: "/"),
            let hostID = UUID(uuidString: String(key[..<separator]))
        else { return nil }
        return .init(hostID: hostID, workspaceID: String(key[key.index(after: separator)...]))
    }
}
