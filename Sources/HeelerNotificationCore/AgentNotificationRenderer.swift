import Foundation

/// What the Notification Service Extension ends up showing: either decrypted
/// Agent Notification content or the generic fallback banner.
struct AgentNotificationAlert: Sendable, Equatable {
    let title: String
    let body: String
}

/// The service extension's logic as a pure function (#71): take the push's
/// `userInfo` and the registered Notification Keys, select the key by the
/// envelope's kid, decrypt, and phrase the alert the way herdr's desktop
/// notification does. Anything undecryptable — missing or non-string
/// envelope, unknown kid, any `NotificationEnvelopeError` — degrades to
/// `fallback`, which the extension applies unconditionally so a forged push
/// can never render attacker-chosen text (spec #68, user story 20).
enum AgentNotificationRenderer {
    /// Mirrors the relay's generic wrap copy; deliberately unalarming.
    static let fallback = AgentNotificationAlert(title: "Heeler", body: "Agent update")

    static func alert(
        userInfo: [AnyHashable: Any], keys: [NotificationKeyRecord]
    ) -> AgentNotificationAlert {
        guard let (_, payload) = NotificationEnvelope.open(userInfo: userInfo, keys: keys)
        else { return fallback }
        return alert(
            workspace: payload.project, tab: payload.tab, session: payload.session,
            agentKind: payload.agentKind, status: payload.status)
    }

    /// The one phrasing of an Agent Notification, shared by the push path
    /// above and the in-app foreground banner (#77) so the wording cannot
    /// drift between them. It matches herdr's desktop notification: title
    /// `claude finished | <session>`, body `<workspace> · <tab>`.
    ///
    /// The session name is what tells parallel Agents apart; the kind stays
    /// the raw herdr id so phone and desktop read the same. The Host is
    /// deliberately absent: it is the same machine every time. The encrypted
    /// wire still calls the workspace `project` for backward compatibility.
    static func alert(
        workspace: String?, tab: String?, session: String?, agentKind: String,
        status: AgentStatus
    ) -> AgentNotificationAlert {
        let headline = "\(agentKind) \(outcome(for: status))"
        let title = nonEmpty(session).map { "\(headline) | \($0)" } ?? headline
        let body = [workspace, tab].compactMap(nonEmpty).joined(separator: " · ")
        return AgentNotificationAlert(title: title, body: body)
    }

    private static func outcome(for status: AgentStatus) -> String {
        switch status {
        case .blocked: "needs input"
        case .done: "finished"
        // The status set is open on the wire; render unrecognized values
        // factually instead of guessing at their meaning.
        default: status.rawValue
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
