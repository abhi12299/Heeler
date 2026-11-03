import Foundation

/// What the user last launched, so the new-agent sheet opens on it (#12,
/// #601): launching several agents into the same project, with the same
/// Agent, is the common case, and re-picking either every time is pure tax.
///
/// The Workspace is remembered per Host because a workspace ID only means
/// something inside one herdr session. The Agent kind is a single preference
/// across Hosts: a Host that lacks it falls back to its own first kind.
struct RecentLaunchStore {
    private static let workspaceKey = "recent-workspace-by-host"
    private static let agentKindKey = "recent-agent-kind"
    private static let agentChoiceKey = "recent-agent-choice-by-host"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workspaceID(for hostID: Host.ID) -> String? {
        workspacesByHost[hostID.uuidString]
    }

    func rememberWorkspace(_ workspaceID: String, for hostID: Host.ID) {
        var updated = workspacesByHost
        updated[hostID.uuidString] = workspaceID
        defaults.set(updated, forKey: Self.workspaceKey)
    }

    /// Nil until the first successful launch, or when a later version drops
    /// the stored kind.
    var agentKind: SupportedAgentKind? {
        defaults.string(forKey: Self.agentKindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    func rememberAgentKind(_ kind: SupportedAgentKind) {
        defaults.set(kind.rawValue, forKey: Self.agentKindKey)
    }

    /// The Agent picker's last launched choice on a Host, stored as
    /// `kind:<raw>` or `custom:<uuid>`, so the form reopens on it.
    func agentChoice(for hostID: Host.ID) -> StartAgentStore.AgentChoice? {
        guard
            let stored = (defaults.dictionary(forKey: Self.agentChoiceKey) as? [String: String])?[
                hostID.uuidString]
        else { return nil }
        if stored.hasPrefix("kind:") {
            return SupportedAgentKind(rawValue: String(stored.dropFirst("kind:".count)))
                .map(StartAgentStore.AgentChoice.builtIn)
        }
        if stored.hasPrefix("custom:") {
            return UUID(uuidString: String(stored.dropFirst("custom:".count)))
                .map(StartAgentStore.AgentChoice.custom)
        }
        return nil
    }

    func rememberAgentChoice(_ choice: StartAgentStore.AgentChoice, for hostID: Host.ID) {
        var updated = defaults.dictionary(forKey: Self.agentChoiceKey) as? [String: String] ?? [:]
        switch choice {
        case .builtIn(let kind): updated[hostID.uuidString] = "kind:\(kind.rawValue)"
        case .custom(let id): updated[hostID.uuidString] = "custom:\(id.uuidString)"
        }
        defaults.set(updated, forKey: Self.agentChoiceKey)
    }

    /// Entries for Hosts that no longer exist are harmless (a few bytes each,
    /// never read), so nothing prunes them.
    private var workspacesByHost: [String: String] {
        defaults.dictionary(forKey: Self.workspaceKey) as? [String: String] ?? [:]
    }
}
