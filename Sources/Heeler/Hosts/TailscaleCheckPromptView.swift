import SwiftUI
import UIKit

/// The card for a pending Tailscale SSH `check` login: tailscaled is holding
/// the connection until the user signs in at the link, and the connection
/// continues by itself once they have.
struct TailscaleCheckPromptCard: View {
    let prompt: TailscaleCheckPrompts.Prompt
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Tailscale SSH check", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button("Hide", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            Text(
                "Your tailnet policy wants a fresh sign-in before \(prompt.host) accepts this "
                    + "connection. Approve it in the browser; Heeler continues once you have.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Login Page") { openURL(prompt.url) }
                    .buttonStyle(.borderedProminent)
                Button("Copy Link") { UIPasteboard.general.url = prompt.url }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

extension View {
    /// Shows pending Tailscale SSH check logins over this view. Applied to the
    /// root and to sheets, since an overlay on the root sits under a sheet.
    func tailscaleCheckPrompt() -> some View {
        modifier(TailscaleCheckPromptModifier())
    }
}

private struct TailscaleCheckPromptModifier: ViewModifier {
    @State private var prompts = TailscaleCheckPrompts.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if let prompt = prompts.current {
                TailscaleCheckPromptCard(prompt: prompt) {
                    prompts.dismiss(prompt.id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: prompts.current)
    }
}
