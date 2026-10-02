import Foundation

/// The workspace the user last started an agent in, remembered per Host (#12).
///
/// The new-agent sheet pre-selects it: launching several agents into the same
/// project is the common case, and re-picking the workspace every time is pure
/// tax. Keyed by Host because a workspace ID only means something inside one
/// herdr session.
struct RecentWorkspaceStore {
    private static let defaultsKey = "recent-workspace-by-host"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workspaceID(for hostID: Host.ID) -> String? {
        byHost[hostID.uuidString]
    }

    func remember(_ workspaceID: String, for hostID: Host.ID) {
        var updated = byHost
        updated[hostID.uuidString] = workspaceID
        defaults.set(updated, forKey: Self.defaultsKey)
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

    private static let agentChoiceKey = "recent-agent-choice-by-host"

    /// Entries for Hosts that no longer exist are harmless (a few bytes each,
    /// never read), so nothing prunes them.
    private var byHost: [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
