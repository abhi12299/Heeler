import SwiftUI

/// Agent search docked to the terminal's leading edge: the mirror of
/// ``WorkspaceTerminalDrawer``. A slim translucent tab that expands in place
/// into a panel listing every running Agent across Workspaces, with a field
/// that searches their transcripts.
///
/// The tab only takes taps and the long press that moves it. A horizontal
/// drag that starts on it is still a back swipe: the system's own on an
/// iPhone, and `onBackSwipe` where the screen draws that gesture itself.
struct AgentSearchDrawer: View {
    let store: AgentSearchStore
    let selectedAgentID: ConsoleAgent.ID
    let edgeDock: EdgeDockSettings
    var palette: TerminalThemePalette = .system
    /// A row's name, as the Agent switcher shows it.
    let title: (ConsoleAgent) -> String
    var onSelect: (ConsoleAgent.ID) -> Void
    /// Set where the screen's own leading-edge gesture lies under the tab.
    var onBackSwipe: (() -> Void)? = nil

    static let handleSize = WorkspaceTerminalDrawer.handleSize
    static let handleHitWidth: CGFloat = 36
    static let panelWidth: CGFloat = 288
    static let headerHeight: CGFloat = 36
    static let fieldHeight: CGFloat = 36
    static let maxPanelHeight: CGFloat = 392
    /// Typing settles for this long before a Host is asked.
    static let searchDelay: Duration = .milliseconds(350)
    /// How far a drag travels before it counts as a back swipe, matching the
    /// screen's own edge gesture.
    static let backSwipeTravel: CGFloat = 72
    private static let nudge: CGFloat = 68

    @State private var isExpanded = false
    @State private var isLifted = false
    @State private var liftTravel: CGFloat = 0
    @FocusState private var fieldIsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The panel takes what the terminal has left above the keyboard, up to
    /// its own limit.
    static func panelHeight(available height: CGFloat) -> CGFloat {
        min(maxPanelHeight, max(0, height))
    }

    /// Whether a drag off the tab is a back swipe: far enough toward the
    /// trailing edge and mostly horizontal.
    static func isBackSwipe(_ translation: CGSize) -> Bool {
        translation.width >= backSwipeTravel
            && abs(translation.height) <= translation.width * 0.75
    }

    /// The surface's own theme colours, like every other floating control.
    func palette(_ palette: TerminalThemePalette) -> Self {
        var copy = self
        copy.palette = palette
        return copy
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let handleTop = WorkspaceTerminalDrawer.handleTop(
                fraction: edgeDock.fraction(for: .agentSearch),
                liftTravel: liftTravel, height: height)
            ZStack(alignment: .topLeading) {
                if isExpanded {
                    // A tap anywhere else closes the panel instead of reaching
                    // the terminal underneath it.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { setExpanded(false) }
                        .accessibilityHidden(true)
                    let panelHeight = Self.panelHeight(available: height)
                    panel(height: panelHeight)
                        .offset(y: WorkspaceTerminalDrawer.panelTop(
                            handleTop: handleTop, panelHeight: panelHeight, height: height))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    handle(top: handleTop, height: height)
                        .offset(y: handleTop)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(palette.foreground)
        .onChange(of: selectedAgentID) { _, _ in
            if isExpanded { setExpanded(false) }
        }
    }

    private func setExpanded(_ expanded: Bool) {
        if !expanded { fieldIsFocused = false }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            isExpanded = expanded
        }
    }

    private func dock(handleTop top: CGFloat, height: CGFloat) {
        edgeDock.setFraction(
            WorkspaceTerminalDrawer.fraction(handleTop: top, height: height), for: .agentSearch)
        liftTravel = 0
    }

    private func handle(top: CGFloat, height: CGFloat) -> some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 13, weight: .semibold))
            .opacity(TerminalFloatingButtonStyle.iconOpacity)
            .frame(width: Self.handleSize.width, height: Self.handleSize.height)
            .background { surface }
            .frame(width: Self.handleHitWidth, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture {
                guard !isLifted else { return }
                setExpanded(true)
            }
            .edgeDockLift(
                isLifted: $isLifted,
                onMove: { liftTravel = $0 },
                onDrop: { travel in
                    dock(handleTop: WorkspaceTerminalDrawer.handleTop(
                        fraction: edgeDock.fraction(for: .agentSearch),
                        liftTravel: travel, height: height), height: height)
                })
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        guard !isLifted, Self.isBackSwipe(value.translation) else { return }
                        onBackSwipe?()
                    },
                including: onBackSwipe == nil ? .subviews : .all)
            .hoverEffect(.highlight)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Agent search")
            .accessibilityValue("\(store.rows.count) agents")
            .accessibilityHint("Lists the running Agents and searches their transcripts")
            .accessibilityAction { setExpanded(true) }
            .accessibilityAction(named: "Move up") {
                dock(handleTop: top - Self.nudge, height: height)
            }
            .accessibilityAction(named: "Move down") {
                dock(handleTop: top + Self.nudge, height: height)
            }
    }

    private func panel(height: CGFloat) -> some View {
        let rows = store.rows
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    setExpanded(false)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide Agent search")
                Text("Agents")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.foreground.opacity(0.7))
                Spacer(minLength: 0)
                if store.isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .tint(palette.foreground)
                        .accessibilityLabel("Searching transcripts")
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 14)
            .frame(height: Self.headerHeight)
            field
            if rows.isEmpty {
                Text(store.isSearching ? "Searching…" : "No matching Agents")
                    .font(.subheadline)
                    .foregroundStyle(palette.foreground.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.immediately)
            }
            if store.searchFailed {
                Text("A Host did not answer; some transcripts were not searched.")
                    .font(.caption2)
                    .foregroundStyle(palette.foreground.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: Self.panelWidth, height: height)
        .background {
            TerminalEdgeTabBackground(
                palette: palette, fillOpacity: TerminalEdgeTabBackground.panelFillOpacity
            )
            .scaleEffect(x: -1, y: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent search")
        // Typing settles before the Hosts are asked; a newer query cancels
        // the wait, and the store drops an answer that lands late.
        .task(id: store.query) {
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled else { return }
            await store.search()
        }
    }

    private var field: some View {
        @Bindable var store = store
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.foreground.opacity(0.5))
                .accessibilityHidden(true)
            TextField(
                "", text: $store.query,
                prompt: Text("Search transcripts")
                    .foregroundStyle(palette.foreground.opacity(0.45)))
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($fieldIsFocused)
                .onSubmit { Task { await store.search() } }
                .accessibilityLabel("Search transcripts")
            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.foreground.opacity(0.5))
                        .frame(width: 28, height: Self.fieldHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, store.query.isEmpty ? 10 : 2)
        .frame(height: Self.fieldHeight)
        .background(palette.foreground.opacity(0.1), in: .rect(cornerRadius: 9))
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
    }

    private func row(_ item: AgentSearchStore.Row) -> some View {
        let selected = item.agent.id == selectedAgentID
        let name = title(item.agent)
        let context = Self.context(for: item.agent)
        return Button {
            // Collapse first: a retained Agent surface survives the switch
            // and would otherwise come back with the panel still open.
            setExpanded(false)
            if !selected {
                onSelect(item.agent.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(uiColor: item.agent.agent.status.inkUIColor))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let context {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(palette.foreground.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                if let snippet = item.snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                palette.foreground.opacity(selected ? 0.16 : 0),
                in: .rect(cornerRadius: 9))
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Agent, \(name)")
        .accessibilityValue(item.snippet ?? context ?? "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Where the Agent runs, since the list spans Workspaces.
    static func context(for agent: ConsoleAgent) -> String? {
        agent.workspaceLabel ?? agent.repoName
    }

    /// The tab's surface, squared off on the leading edge it is docked to.
    private var surface: some View {
        TerminalEdgeTabBackground(palette: palette)
            .scaleEffect(x: -1, y: 1)
    }
}
