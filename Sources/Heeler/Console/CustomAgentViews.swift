import SwiftUI

/// The saved Custom Agents: add, edit, and delete the launch profiles the New
/// Agent picker offers alongside the detected kinds.
struct CustomAgentListView: View {
    @State private var store = CustomAgentStore.shared
    @State private var editing: CustomAgent?

    var body: some View {
        List {
            Section {
                ForEach(store.agents) { agent in
                    Button {
                        editing = agent
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.trimmedName.isEmpty ? "Untitled" : agent.trimmedName)
                                .foregroundStyle(.primary)
                            Text(CustomAgentPreview.commandLine(for: agent))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.delete(store.agents[index].id) }
                }
            } footer: {
                Text(
                    "Runs one of your shell aliases or commands, like cg, in a new pane. A Host "
                        + "offers each one where the Agent it starts is installed.")
            }
        }
        .overlay {
            if store.agents.isEmpty {
                ContentUnavailableView(
                    "No Custom Agents",
                    systemImage: "terminal",
                    description: Text("Add one to start an Agent through your own shell alias."))
            }
        }
        .navigationTitle("Custom Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    editing = CustomAgent(name: "", kind: .claude)
                }
            }
        }
        .sheet(item: $editing) { agent in
            NavigationStack {
                CustomAgentEditorView(agent: agent) { saved in
                    store.save(saved)
                    editing = nil
                } onCancel: {
                    editing = nil
                }
            }
        }
    }
}

/// One Custom Agent's form. Nothing is saved until Save, and Save stays off
/// while the profile would not launch.
struct CustomAgentEditorView: View {
    @State private var draft: CustomAgent
    let onSave: (CustomAgent) -> Void
    let onCancel: () -> Void

    init(
        agent: CustomAgent, onSave: @escaping (CustomAgent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: agent)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. cg", text: $draft.name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(
                    "Command (default: \(draft.trimmedName.isEmpty ? "the name" : draft.trimmedName))",
                    text: $draft.command
                )
                .font(.callout.monospaced())
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Command")
                Picker("Starts", selection: $draft.kind) {
                    ForEach(SupportedAgentKind.allCases) { kind in
                        Text("\(kind.displayName) (\(kind.executable))").tag(kind.rawValue)
                    }
                }
            } footer: {
                Text(
                    "Typed into the Host's shell, so your aliases and functions work: name it cg "
                        + "and it runs your cg. A valid agent name (lowercase, digits, - or _) also "
                        + "names the agents it starts.")
            }

            Section {
                AgentArgumentsField(
                    text: $draft.arguments,
                    placeholder: "e.g. --dangerously-skip-permissions")
            } header: {
                Text("Arguments")
            } footer: {
                if case .failure(let error) = draft.parsedArguments {
                    Text(error.message).foregroundStyle(.red)
                } else {
                    Text("Added after the command, before any arguments typed on the New Agent form.")
                }
            }

            Section {
                TextEditor(text: $draft.environment)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 88)
                    .accessibilityLabel("Environment")
            } header: {
                Text("Environment")
            } footer: {
                if case .failure(let error) = draft.parsedEnvironment {
                    Text(error.message).foregroundStyle(.red)
                } else {
                    Text(
                        "One KEY=VALUE per line, e.g. CLAUDE_CONFIG_DIR=~/.claude-work. "
                            + "~ and $HOME become the Host's home directory.")
                }
            }

            Section("Runs") {
                Text(CustomAgentPreview.commandLine(for: draft))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(draft.trimmedName.isEmpty ? "Custom Agent" : draft.trimmedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = draft
                    saved.name = draft.trimmedName
                    onSave(saved)
                }
                .disabled(draft.validationMessage != nil)
            }
        }
    }
}

/// The shell line a Custom Agent amounts to, for the editor and the list.
enum CustomAgentPreview {
    static func commandLine(for agent: CustomAgent) -> String {
        var parts: [String] = []
        if case .success(let entries) = agent.parsedEnvironment {
            parts += entries.map { "\($0.key)=\(environmentValue($0.value))" }
        }
        parts.append(agent.resolvedCommand)
        if case .success(let arguments) = agent.parsedArguments {
            parts += arguments.map(ShellWord.quoted)
        }
        return parts.joined(separator: " ")
    }

    /// A leading `~` stays bare: it becomes the Host's home before launch,
    /// just as the shell would expand it.
    private static func environmentValue(_ value: String) -> String {
        guard value.hasPrefix("~/") else { return ShellWord.quoted(value) }
        return "~" + ShellWord.quoted(String(value.dropFirst()))
    }
}
