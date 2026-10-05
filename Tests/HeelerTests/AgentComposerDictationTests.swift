import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The Composer's Dictate button starts keyboard dictation by answering
// UIKit's input-mode query with the system's dictation mode. The Simulator
// lists no such mode, so these tests script the available modes.

@MainActor
@Suite("Agent Composer dictation")
struct AgentComposerDictationTests {
    private final class ScriptedInputMode: UITextInputMode {
        private let language: String?

        init(language: String?) {
            self.language = language
            super.init()
        }

        required init?(coder: NSCoder) {
            language = nil
            super.init(coder: coder)
        }

        override var primaryLanguage: String? { language }
    }

    private let english = ScriptedInputMode(language: "en-US")
    private let dictation = ScriptedInputMode(language: "dictation")

    private func composer(modes: [UITextInputMode]) -> AgentComposerUITextView {
        let composer = AgentComposerUITextView()
        composer.availableInputModes = { modes }
        return composer
    }

    @Test func findsTheDictationModeAmongTheActiveOnes() {
        #expect(
            AgentComposerUITextView.dictationMode(in: [english, dictation]) === dictation)
        #expect(AgentComposerUITextView.dictationMode(in: [english]) == nil)
        #expect(AgentComposerUITextView.dictationMode(in: []) == nil)
    }

    @Test func anUnarmedComposerOpensTheOrdinaryKeyboard() {
        let composer = composer(modes: [english, dictation])

        #expect(!composer.isDictationArmed)
        #expect(composer.textInputMode !== dictation)
    }

    @Test func anArmedComposerOpensInDictation() {
        let composer = composer(modes: [english, dictation])

        composer.armDictation()

        #expect(composer.isDictationArmed)
        #expect(composer.textInputMode === dictation)
    }

    /// Dictation turned off in Settings removes the mode; the button then
    /// only focuses the draft.
    @Test func anArmedComposerFallsBackWhenDictationIsUnavailable() {
        let composer = composer(modes: [english])

        composer.armDictation()

        #expect(composer.textInputMode !== dictation)
    }

    @Test func theRequestLapsesSoLaterFocusOpensTheOrdinaryKeyboard() async throws {
        let composer = composer(modes: [english, dictation])

        composer.armDictation()
        try await Task.sleep(
            for: .seconds(AgentComposerUITextView.dictationArmWindow + 0.5))

        #expect(!composer.isDictationArmed)
        #expect(composer.textInputMode !== dictation)
    }
}
