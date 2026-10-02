import Foundation
import Testing

@testable import Heeler

/// Tailscale SSH banner handling: the `check` login URL and refusal text
/// arrive as SSH auth banners, worded by tailscaled and its control plane.
@Suite("Tailscale SSH banners")
struct TailscaleSSHTests {
    @Test func findsTheCheckLoginURL() {
        let banner =
            "# Tailscale SSH requires an additional check.\n"
            + "# To authenticate, visit: https://login.tailscale.com/a/l5c3b2a1d0e9f8\n"
        #expect(
            TailscaleSSH.loginURL(inBanner: banner)
                == URL(string: "https://login.tailscale.com/a/l5c3b2a1d0e9f8"))
    }

    @Test func aBannerWithoutALinkIsNoPrompt() {
        let banner = "# Authentication checked with Tailscale SSH.\n# Time since last: 0s\n"
        #expect(TailscaleSSH.loginURL(inBanner: banner) == nil)
    }

    @Test func refusalIsTailscaledsOwnWordsOnOneLine() {
        let banner = "tailscale: tailnet policy does not permit you to SSH as user \"root\"\n"
        #expect(
            TailscaleSSH.denialMessage(fromBanner: banner)
                == "tailnet policy does not permit you to SSH as user \"root\"")
    }

    @MainActor @Test func aFinishedAttemptCannotPromptAgain() {
        let prompts = TailscaleCheckPrompts()
        let attempt = UUID()
        let url = URL(string: "https://login.tailscale.com/a/x")!
        prompts.present(.init(id: attempt, host: "abhi-mac", url: url))
        #expect(prompts.current?.id == attempt)
        prompts.finish(attempt)
        #expect(prompts.current == nil)
        prompts.present(.init(id: attempt, host: "abhi-mac", url: url))
        #expect(prompts.current == nil)
    }
}
