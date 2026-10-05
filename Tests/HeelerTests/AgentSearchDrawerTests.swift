import SwiftUI
import Testing
import UIKit

@testable import Heeler

@MainActor
@Suite("agent search drawer")
struct AgentSearchDrawerTests {
    private static let host = UUID()

    private static func agent(
        _ pane: String, name: String?, session: String, kind: String = "claude"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host,
            hostName: "mac",
            agent: Agent(
                terminalID: "term-\(pane)", kind: kind, title: "", status: .working,
                workspaceID: String(pane.prefix(2)), tabID: "\(pane):t", paneID: pane,
                cwd: "/srv/app", revision: 0, name: name,
                agentSession: AgentSessionInfo(
                    agent: kind, kind: .id, source: "herdr:\(kind)", value: session)),
            workspaceLabel: "space-\(pane.prefix(2))",
            repositoryCheckout: nil)
    }

    /// A drag off the tab reaches the screen's back gesture only when it
    /// reads as one: far enough, and mostly sideways.
    @Test func onlyALongSidewaysDragOffTheTabIsABackSwipe() {
        #expect(AgentSearchDrawer.isBackSwipe(CGSize(width: 90, height: 10)))
        #expect(!AgentSearchDrawer.isBackSwipe(CGSize(width: 40, height: 0)))
        #expect(!AgentSearchDrawer.isBackSwipe(CGSize(width: 90, height: 80)))
        #expect(!AgentSearchDrawer.isBackSwipe(CGSize(width: -90, height: 0)))
    }

    /// Two Agents in one Tab share its place name, so a row leads with the
    /// Agent's own name and says which kind it is beside where it runs.
    @Test func aRowLeadsWithTheAgentsOwnNameAndSaysItsKind() {
        let named = Self.agent("w1:p1", name: "elephants", session: "s-1", kind: "codex")
        let unnamed = Self.agent("w1:p2", name: nil, session: "s-2")

        let namedLabels = AgentSearchDrawer.labels(for: named, location: "heeler · cg")
        let unnamedLabels = AgentSearchDrawer.labels(for: unnamed, location: "heeler · cg")

        #expect(namedLabels.title == "elephants")
        #expect(namedLabels.detail == "codex · heeler · cg")
        #expect(unnamedLabels.title == "claude")
        #expect(unnamedLabels.detail == "heeler · cg")
    }

    @Test func thePanelFitsWhatTheKeyboardLeaves() {
        #expect(AgentSearchDrawer.panelHeight(available: 700) == AgentSearchDrawer.maxPanelHeight)
        #expect(AgentSearchDrawer.panelHeight(available: 240) == 240)
        #expect(AgentSearchDrawer.panelHeight(available: -4) == 0)
    }

    @Test func theTabRestsOnTheLeadingEdgeAndOpensTheSearchableAgentList() async throws {
        // Existing hosting tests use this boundary: older runtimes do not
        // materialize SwiftUI AX elements without an assistive client.
        guard #available(iOS 27, *) else { return }
        let agents = [
            Self.agent("w1:p1", name: "relay-fix", session: "s-1"),
            Self.agent("w2:p1", name: "docs", session: "s-2"),
            Self.agent("w3:p1", name: "billing", session: "s-3"),
        ]
        let store = AgentSearchStore(agents: { agents }) { _, _ in
            [TranscriptSearchHit(sessionID: "s-3", role: .assistant, snippet: "the relay restarted")]
        }
        var selected: [ConsoleAgent.ID] = []
        let controller = UIHostingController(rootView:
            AgentSearchDrawer(
                store: store, selectedAgentID: agents[0].id,
                edgeDock: EdgeDockSettings(defaults: try #require(
                    UserDefaults(suiteName: "AgentSearchDrawerTests.\(UUID().uuidString)"))),
                location: { $0.workspaceLabel ?? "" },
                onSelect: { selected.append($0) }))
        controller.safeAreaRegions = []
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 320, height: 640), rootViewController: controller)
        defer { window.isHidden = true }

        // Collapsed: only the tab, docked to the leading edge.
        let tab = try await accessible("Agent search", in: controller.view)
        #expect(tab.accessibilityValue == "3 agents")
        let tabFrame = Self.frame(of: tab, in: controller.view)
        #expect(tabFrame.minX == 0, "Docked to the leading edge: \(tabFrame)")
        #expect(tabFrame.width <= AgentSearchDrawer.handleHitWidth)
        #expect(Self.elements(in: controller.view)
            .contains { $0.accessibilityLabel == "Agent, docs" } == false,
            "Rows stay hidden until the tab is tapped")

        // Expanded with no query: every running Agent, current one marked.
        #expect(tab.accessibilityActivate())
        let current = try await accessible("Agent, relay-fix", in: controller.view)
        _ = try await accessible("Agent, docs", in: controller.view)
        _ = try await accessible("Agent, billing", in: controller.view)
        #expect(current.accessibilityTraits.contains(.selected))

        // A query keeps the Agent named for it and the one whose transcript
        // holds it, with the words around the match.
        store.query = "relay"
        await store.search()
        var billing: NSObject?
        for _ in 0..<40 {
            controller.view.layoutIfNeeded()
            let elements = Self.elements(in: controller.view)
            billing = elements.first { $0.accessibilityLabel == "Agent, billing" }
            if billing?.accessibilityValue == "the relay restarted",
                !elements.contains(where: { $0.accessibilityLabel == "Agent, docs" })
            {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(billing?.accessibilityValue == "the relay restarted")
        #expect(Self.elements(in: controller.view)
            .contains { $0.accessibilityLabel == "Agent, docs" } == false)

        #expect(try #require(billing).accessibilityActivate())
        #expect(selected == [agents[2].id])
    }

    private func accessible(_ label: String, in root: UIView) async throws -> NSObject {
        for _ in 0..<40 {
            root.layoutIfNeeded()
            if let element = Self.elements(in: root).first(where: { $0.accessibilityLabel == label }) {
                return element
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(nil as NSObject?, "Missing accessibility element: \(label)")
    }

    private static func elements(in root: UIView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted,
                  !node.accessibilityElementsHidden else { return }
            result.append(node)
            for object in node.accessibilityElements ?? [] {
                if let object = object as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }

    private static func frame(of element: NSObject, in root: UIView) -> CGRect {
if let view = element as? UIView { return view.convert(view.bounds, to: root) }
        return root.convert(element.accessibilityFrame, from: nil)
    }
}
