import Foundation
import Testing

@testable import Heeler

/// Custom Agents: the environment syntax a profile accepts, home expansion,
/// validation, on-device persistence, and the command line the editor shows.
@Suite("Custom agents")
struct CustomAgentTests {
    private typealias Entry = CustomAgent.EnvironmentEntry

    @Test func environmentReadsLinesPastedFromAShellProfile() throws {
        let text = """
            # work account
            export CLAUDE_CONFIG_DIR="$HOME/.claude-gocomply"

            MODEL='opus 5'
            EMPTY=
            URL=https://example.com/a=b
            """
        let entries = try CustomAgent.parseEnvironment(text).get()
        #expect(
            entries == [
                Entry(key: "CLAUDE_CONFIG_DIR", value: "$HOME/.claude-gocomply"),
                Entry(key: "MODEL", value: "opus 5"),
                Entry(key: "EMPTY", value: ""),
                Entry(key: "URL", value: "https://example.com/a=b"),
            ])
    }

    @Test(arguments: [
        ("JUST_A_WORD", CustomAgent.EnvironmentError.missingEquals(line: 1)),
        ("1BAD=x", .invalidKey("1BAD")),
        ("WITH-DASH=x", .invalidKey("WITH-DASH")),
        ("=value", .invalidKey("")),
        ("A=1\nA=2", .duplicateKey("A")),
    ])
    func environmentRejectsWhatAShellWouldNotExport(
        text: String, error: CustomAgent.EnvironmentError
    ) {
        #expect(CustomAgent.parseEnvironment(text) == .failure(error))
    }

    @Test func homeExpandsOnlyWhereAShellWouldHaveExpandedIt() {
        let home = "/Users/abhi"
        #expect(CustomAgent.expandingHome("~", home: home) == "/Users/abhi")
        #expect(CustomAgent.expandingHome("~/.claude", home: home) == "/Users/abhi/.claude")
        #expect(CustomAgent.expandingHome("$HOME/x", home: home) == "/Users/abhi/x")
        #expect(CustomAgent.expandingHome("${HOME}/x", home: home) == "/Users/abhi/x")
        #expect(CustomAgent.expandingHome("~other/x", home: home) == "~other/x")
        #expect(CustomAgent.expandingHome("/opt/~/x", home: home) == "/opt/~/x")
    }

    @Test func onlyHomeReferencesNeedTheHomeProbe() {
        #expect(CustomAgent.needsHome([Entry(key: "A", value: "~/x")]))
        #expect(CustomAgent.needsHome([Entry(key: "A", value: "${HOME}")]))
        #expect(!CustomAgent.needsHome([Entry(key: "A", value: "/opt/x"), Entry(key: "B", value: "~x")]))
    }

    @Test func validationNamesTheFirstProblem() {
        #expect(CustomAgent(name: " ", kind: .claude).validationMessage == "Give it a name.")
        #expect(
            CustomAgent(name: "q", kind: .claude, arguments: "'open").validationMessage
                == StartAgentStore.ArgumentError.unclosedSingleQuote.message)
        #expect(
            CustomAgent(name: "e", kind: .claude, environment: "NOPE").validationMessage
                == "Line 1 is not KEY=VALUE.")
        #expect(CustomAgent(name: "cg", kind: .claude).validationMessage == nil)
    }

    @Test func aKindThisBuildDoesNotKnowSurvivesDecodingButCannotLaunch() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"future","kind":"newagent","arguments":"","environment":""}]"#
        let agents = try JSONDecoder().decode([CustomAgent].self, from: Data(json.utf8))
        #expect(agents.first?.supportedKind == nil)
        #expect(agents.first?.validationMessage == "newagent is not an Agent this app can launch.")
    }

    @MainActor @Test func theStorePersistsAddsEditsAndDeletes() {
        let name = "custom-agents-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let store = CustomAgentStore(defaults: defaults)
        var cg = CustomAgent(name: "cg", kind: .claude, arguments: "--dangerously-skip-permissions")
        store.save(cg)
        cg.environment = "CLAUDE_CONFIG_DIR=~/.claude-gocomply"
        store.save(cg)
        store.save(CustomAgent(name: "c", kind: .claude))

        let reloaded = CustomAgentStore(defaults: defaults)
        #expect(reloaded.agents.map(\.name) == ["cg", "c"])
        #expect(reloaded.agent(id: cg.id)?.environment == "CLAUDE_CONFIG_DIR=~/.claude-gocomply")

        reloaded.delete(cg.id)
        #expect(CustomAgentStore(defaults: defaults).agents.map(\.name) == ["c"])
    }

    @Test func thePreviewReadsLikeTheLineTypedIntoTheShell() {
        #expect(CustomAgentPreview.commandLine(for: CustomAgent(name: "cg", kind: .claude)) == "cg")
        let spelledOut = CustomAgent(
            name: "work", kind: .claude, command: "claude",
            arguments: #"--dangerously-skip-permissions --model "opus 5""#,
            environment: "CLAUDE_CONFIG_DIR=~/.claude-gocomply")
        #expect(
            CustomAgentPreview.commandLine(for: spelledOut)
                == "CLAUDE_CONFIG_DIR=~/.claude-gocomply claude --dangerously-skip-permissions --model 'opus 5'")
    }

    /// The point of a Custom Agent: naming it after an alias runs the alias.
    @Test func theCommandIsTheNameUnlessOneIsGiven() {
        #expect(CustomAgent(name: " cg ", kind: .claude).resolvedCommand == "cg")
        #expect(
            CustomAgent(name: "Work Claude", kind: .claude, command: " cg --resume ").resolvedCommand
                == "cg --resume")
    }

    @Test func aNameThatIsNoCommandNeedsOne() {
        #expect(
            CustomAgent(name: "Work Claude", kind: .claude).validationMessage
                == "Enter the command to run; the name is not one.")
        #expect(CustomAgent(name: "Work Claude", kind: .claude, command: "cg").validationMessage == nil)
        #expect(
            CustomAgent(name: "cg", kind: .claude, command: "cg\nrm -rf ~").validationMessage
                == "Keep the command on one line.")
    }

    /// Profiles saved before the command existed keep working, and run the
    /// alias they were named after.
    @Test func aProfileSavedWithoutACommandRunsItsName() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","name":"cg","kind":"claude","arguments":"","environment":""}]"#
        let agents = try JSONDecoder().decode([CustomAgent].self, from: Data(json.utf8))
        #expect(agents.first?.command == "")
        #expect(agents.first?.resolvedCommand == "cg")
    }

    @Test func typedArgumentsReachTheCommandAsSingleWords() {
        let request = AgentLaunchRequest(
            kind: "claude", name: "cg",
            arguments: ["--model", "opus 5", "it's", "$HOME", "", "a=b/c.d"],
            shellCommand: "cg")
        #expect(
            request.typedCommandLine
                == #"cg --model 'opus 5' 'it'\''s' '$HOME' '' a=b/c.d"#)
    }
}
