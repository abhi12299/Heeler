import Foundation
import Observation

/// A user-defined launch over a shell command — typically one of the user's
/// own aliases or functions, such as `cg() { CLAUDE_CONFIG_DIR=… claude
/// --dangerously-skip-permissions "$@"; }`. herdr's `agent.start` only types
/// a supported kind's own executable, which bypasses aliases, so a Custom
/// Agent instead types its command into the fresh pane's interactive shell,
/// where the user's aliases and functions are defined, and herdr detects the
/// Agent it starts as it would one typed at the keyboard. Environment
/// variables travel on the `tab.create`/`workspace.create` that opens the
/// pane and are inherited by that shell.
struct CustomAgent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    /// What the picker shows, the command when `command` is empty, and the
    /// default agent name when it is a valid herdr agent name (`cg`, `cg-2`).
    var name: String
    /// The Agent the command starts: a Host offers the profile only where
    /// this kind is installed. Stored raw so a kind this build no longer
    /// knows keeps the profile instead of failing the whole list.
    var kind: String
    /// The shell command typed into the pane, e.g. `cg`. Empty runs the name.
    var command: String
    /// Arguments in the New Agent field's syntax (quotes, backslash escapes),
    /// quoted again onto the command line.
    var arguments: String
    /// `KEY=VALUE` per line. A value starting with `~` is expanded to the
    /// Host's home directory at launch.
    var environment: String

    init(
        id: UUID = UUID(), name: String, kind: SupportedAgentKind, command: String = "",
        arguments: String = "", environment: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind.rawValue
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, command, arguments, environment
    }

    /// Profiles saved before `command` existed decode with it empty, which
    /// runs their name — the alias they were named after.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(String.self, forKey: .kind)
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try container.decode(String.self, forKey: .arguments)
        environment = try container.decode(String.self, forKey: .environment)
    }

    /// The command typed into the shell: `command`, or the name when empty.
    var resolvedCommand: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? trimmedName : trimmed
    }

    var supportedKind: SupportedAgentKind? { SupportedAgentKind(rawValue: kind) }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var parsedArguments: Result<[String], StartAgentStore.ArgumentError> {
        StartAgentStore.parseArguments(StartAgentStore.normalizeSmartPunctuation(arguments))
    }

    var parsedEnvironment: Result<[EnvironmentEntry], EnvironmentError> {
        Self.parseEnvironment(environment)
    }

    struct EnvironmentEntry: Hashable, Sendable {
        let key: String
        let value: String
    }

    enum EnvironmentError: Error, Equatable {
        case missingEquals(line: Int)
        case invalidKey(String)
        case duplicateKey(String)

        var message: String {
            switch self {
            case .missingEquals(let line): "Line \(line) is not KEY=VALUE."
            case .invalidKey(let key): "\(key) is not a valid variable name."
            case .duplicateKey(let key): "\(key) is set twice."
            }
        }
    }

    /// One `KEY=VALUE` per line; blank lines and `#` comments are skipped, a
    /// leading `export ` is tolerated, and one layer of matching quotes around
    /// the value is removed, so a line pasted from a shell profile works.
    static func parseEnvironment(_ text: String) -> Result<[EnvironmentEntry], EnvironmentError> {
        var entries: [EnvironmentEntry] = []
        var seen: Set<String> = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = line.dropFirst("export ".count).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = line.firstIndex(of: "=") else {
                return .failure(.missingEquals(line: index + 1))
            }
            let key = String(line[..<equals])
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                return .failure(.invalidKey(key))
            }
            guard seen.insert(key).inserted else { return .failure(.duplicateKey(key)) }
            var value = String(line[line.index(after: equals)...])
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
                value.last == first
            {
                value = String(value.dropFirst().dropLast())
            }
            entries.append(EnvironmentEntry(key: key, value: value))
        }
        return .success(entries)
    }

    /// Expands a leading `~` (alone or before `/`) and `$HOME`/`${HOME}`
    /// against the Host's home directory: herdr hands environment values to
    /// the shell verbatim, so nothing else would.
    static func expandingHome(_ value: String, home: String) -> String {
        var expanded = value
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst()
        }
        return expanded
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)
    }

    /// Whether any value needs the Host's home directory resolved first.
    static func needsHome(_ entries: [EnvironmentEntry]) -> Bool {
        entries.contains {
            $0.value == "~" || $0.value.hasPrefix("~/") || $0.value.contains("$HOME")
                || $0.value.contains("${HOME}")
        }
    }

    /// The first problem that would stop a launch, for the editor's footer.
    var validationMessage: String? {
        if trimmedName.isEmpty { return "Give it a name." }
        if supportedKind == nil { return "\(kind) is not an Agent this app can launch." }
        if resolvedCommand.contains(where: \.isNewline) { return "Keep the command on one line." }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            trimmedName.wholeMatch(of: /[A-Za-z0-9_.+:@\/-]+/) == nil
        {
            return "Enter the command to run; the name is not one."
        }
        if case .failure(let error) = parsedArguments { return error.message }
        if case .failure(let error) = parsedEnvironment { return error.message }
        return nil
    }
}

/// The saved Custom Agents, on this device only. They describe the user's
/// own launch habits rather than a Host, so every Host offers them wherever
/// their base kind is installed.
@MainActor @Observable
final class CustomAgentStore {
    static let shared = CustomAgentStore()
    private static let defaultsKey = "customAgents"

    private(set) var agents: [CustomAgent]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agents =
            defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([CustomAgent].self, from: $0) } ?? []
    }

    func agent(id: CustomAgent.ID) -> CustomAgent? {
        agents.first { $0.id == id }
    }

    func save(_ agent: CustomAgent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        persist()
    }

    func delete(_ id: CustomAgent.ID) {
        agents.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(agents) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
