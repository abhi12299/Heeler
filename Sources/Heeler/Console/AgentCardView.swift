import SwiftUI
import UIKit

/// The shared Agent Row Layout leads each card; status and Heeler Pin end
/// Row 1, the Host name ends the first additional row, and the Checkout's
/// Changes totals end the last one, after the Host when that is the same
/// row (both share a line of their own when Row 1 is the only row). Fields
/// retain their emphasis using accessible semantic colors; plugin colors
/// and weights do not replace app typography.
struct AgentCardView: View {
    let agent: ConsoleAgent
    var layout: AgentRowLayout = .heelerDefault
    var isPinned: Bool = false
    /// The Agents list's read of this Agent's Checkout; nil where the card
    /// is only a preview.
    var changes: ChangesStore? = nil
    /// Totals shown in place of a read, for the Agent List Fields preview.
    var sampleChanges: ChangesBadge? = nil

    private var totalsSource: ChangesRowTotals.Source? {
        if let changes { .store(changes) } else { sampleChanges.map { .sample($0) } }
    }

    private var presentation: AgentCardPresentation {
        AgentCardPresentation(agent: agent, layout: layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Centered, not baseline-aligned: the status capsule is smaller
            // type with padding, so baseline alignment drops it below Row 1.
            HStack(alignment: .center) {
                AgentRowText(tokens: presentation.rows.first ?? [])
                    .font(.headline)
                    .lineLimit(1)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .layoutPriority(1)
                        .accessibilityLabel("Pinned")
                }
                Spacer(minLength: 8)
                AgentStatusBadge(status: agent.agent.status)
            }
            let additionalRows = Array(presentation.rows.dropFirst())
            ForEach(Array(additionalRows.enumerated()), id: \.offset) { index, row in
                let isLast = index == additionalRows.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AgentRowText(tokens: row, isSecondary: true)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // The Host and the totals keep their width; the row's
                    // fields truncate first.
                    if index == 0 || isLast {
                        Spacer(minLength: 8)
                    }
                    if index == 0 {
                        hostText.layoutPriority(1)
                    }
                    if isLast, let totalsSource {
                        ChangesRowTotals(source: totalsSource).layoutPriority(1)
                    }
                }
            }
            if additionalRows.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Spacer(minLength: 0)
                    hostText
                    if let totalsSource {
                        ChangesRowTotals(source: totalsSource).layoutPriority(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        // Terminal blank rows become bounded extra card spacing on a phone.
        .padding(.bottom, CGFloat(min(layout.rowGap, 3)) * 8)
    }

    /// What ends a card's second line: the Host, and before it the kind of
    /// an Agent whose name no longer says what it is.
    static func trailingContext(for agent: ConsoleAgent) -> String {
        let kind = agent.agent.kind
        guard let name = agent.agent.name, name != kind, !kind.isEmpty else { return agent.hostName }
        return agent.hostName.isEmpty ? kind : "\(kind) · \(agent.hostName)"
    }

    private var hostText: some View {
        Text(verbatim: Self.trailingContext(for: agent))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Keep per-field emphasis through the final Text instead of flattening the
/// rendered tokens into a String. Separators retain the row's base emphasis.
struct AgentRowText: View {
    let tokens: [RenderedToken]
    var isSecondary = false

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for token in tokens {
            var span = AttributedString(token.text)
            let color: UIColor = if token.dim == true {
                isSecondary ? .tertiaryLabel : .secondaryLabel
            } else {
                isSecondary ? .secondaryLabel : .label
            }
            span.foregroundColor = Color(uiColor: color)
            result.append(span)
        }
        return result
    }
}

struct AgentCardPresentation: Equatable, Sendable {
    let rows: [[RenderedToken]]

    var headline: String { rows.first?.map(\.text).joined() ?? "Agent" }
    var additionalRows: [String] { rows.dropFirst().map { $0.map(\.text).joined() } }

    init(agent: ConsoleAgent, layout: AgentRowLayout = .heelerDefault) {
        let rendered = AgentRowRenderer.render(layout: layout, agent: agent)
        if rendered.isEmpty {
            let name = agent.agent.displayName
            rows = [[RenderedToken(
                token: .agent,
                text: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name,
                fg: nil, bold: nil, dim: nil)]]
        } else {
            rows = rendered
        }
    }

    /// Bound by graphemes, preserving literal plugin text and whole emoji.
    var switcherTitle: String {
        let singleLine = headline.components(separatedBy: .newlines).joined(separator: " ")
        return singleLine.count > 48 ? String(singleLine.prefix(47)) + "…" : singleLine
    }
}

/// Status rendered as a tinted capsule; Blocked gets the loudest color
/// because it is the one asking for the user. Working keeps a live solving
/// orb inside the capsule — a still badge cannot tell a busy Agent from a
/// finished one at a glance.
struct AgentStatusBadge: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 12)
                    .accessibilityHidden(true)
            }
            Text(status.rawValue.capitalized)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(status.tintUIColor).opacity(0.15), in: Capsule())
        .foregroundStyle(Color(status.inkUIColor))
    }
}

#Preview {
    List {
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_a", kind: "claude", title: "Fix the flaky test",
                    status: .blocked, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                    cwd: "/work/proj", revision: 3),
                workspaceLabel: "proj",
                repositoryCheckout: RepositoryCheckout(
                    repoKey: "/work/proj/.git",
                    repoName: "proj",
                    repoRoot: "/work/proj",
                    checkoutPath: "/work/proj-wt",
                    isLinkedWorktree: true),
                lastOutputSnippet: "Allow Claude to run rm -rf? 1. Yes 2. No"))
        // No workspace in the snapshot: the Agent's own name takes the lead.
        AgentCardView(
            agent: ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_b", kind: "claude", title: "Draft the release notes",
                    status: .working, workspaceID: "w2", tabID: "w2:t1", paneID: "w2:p1",
                    cwd: "/tmp", revision: 1),
                workspaceLabel: nil,
                repositoryCheckout: nil,
                lastOutputSnippet: nil))
    }
}
