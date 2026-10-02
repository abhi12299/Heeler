import Foundation
import Observation
import Synchronization

/// Tailscale SSH: tailscaled answers port 22 on tailnet addresses and
/// authorizes by the client's tailnet identity and the tailnet ACL, never by a
/// client credential. It takes SSH `none` authentication, and under a `check`
/// policy holds that request open while it waits for a browser login,
/// announcing the login URL in an auth banner first. A refusal arrives as a
/// banner too (`tailscale: tailnet policy does not permit you to SSH as user
/// "root"`), followed by a bare failure.
enum TailscaleSSH {
    /// How long one authentication may be held for a `check` login. tailscaled
    /// itself waits up to 30 minutes; this is a person switching to a browser,
    /// signing in, and coming back.
    static let authenticationBudget: Duration = .seconds(300)

    /// The login URL a `check` banner carries, if any.
    static func loginURL(inBanner banner: String) -> URL? {
        guard let match = banner.firstMatch(of: /https:\/\/[^\s"'<>]+/) else { return nil }
        return URL(string: String(match.output))
    }

    /// A refusal banner as one line of tailscaled's own words.
    static func denialMessage(fromBanner banner: String) -> String {
        var text = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("tailscale: ") {
            text.removeFirst("tailscale: ".count)
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// Collects the banners of one authentication attempt; written from the SSH
/// driver, read once the attempt ends.
final class TailscaleBannerLog: Sendable {
    private let banners = Mutex<[String]>([])

    func append(_ banner: String) {
        banners.withLock { $0.append(banner) }
    }

    var last: String? {
        banners.withLock { $0.last }
    }
}

/// The pending Tailscale SSH `check` logins, shown app-wide so a connection
/// held for a browser login is never a silent spinner. One prompt per
/// authentication attempt; it disappears when that attempt ends either way.
@MainActor @Observable
final class TailscaleCheckPrompts {
    static let shared = TailscaleCheckPrompts()

    struct Prompt: Identifiable, Equatable {
        let id: UUID
        /// The Host as the user knows it (its address).
        let host: String
        let url: URL
    }

    private(set) var prompts: [Prompt] = []
    /// Attempts already finished, so a banner that lands after its attempt
    /// ended cannot resurrect a stale prompt.
    @ObservationIgnored private var finished: Set<UUID> = []

    var current: Prompt? { prompts.first }

    func present(_ prompt: Prompt) {
        guard !finished.contains(prompt.id) else { return }
        prompts.removeAll { $0.id == prompt.id }
        prompts.append(prompt)
    }

    func finish(_ id: UUID) {
        finished.insert(id)
        prompts.removeAll { $0.id == id }
    }

    func dismiss(_ id: UUID) {
        prompts.removeAll { $0.id == id }
    }
}
