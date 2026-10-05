import Foundation
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The Composer's Dictate button writes a live transcript into the draft.
// The Simulator cannot recognise speech, so the store runs against a
// scripted engine.

@MainActor
private final class ScriptedDictationEngine: DictationEngine {
    var startError: DictationError?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncStream<String>.Continuation?

    func start() async throws -> AsyncStream<String> {
        startCount += 1
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
    }

    func hear(_ transcript: String) {
        continuation?.yield(transcript)
    }
}

@MainActor
@Suite("Agent Composer dictation")
struct AgentComposerDictationTests {
    private final class Draft {
        var text: String
        var selection: NSRange

        init(_ text: String, caret: Int? = nil) {
            self.text = text
            selection = NSRange(location: caret ?? (text as NSString).length, length: 0)
        }
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
    }

    private func begin(
        _ store: ComposerDictationStore, in draft: Draft
    ) {
        store.toggle(draft: draft.text, selection: draft.selection) { text, selection in
            draft.text = text
            draft.selection = selection
        }
    }

    @Test func aRevisedTranscriptReplacesItselfInTheDraft() async {
        let engine = ScriptedDictationEngine()
        let store = ComposerDictationStore(engine: engine)
        let draft = Draft("")

        begin(store, in: draft)
        await settle { store.state == .listening }
        engine.hear("fix the")
        await settle { draft.text == "fix the" }
        engine.hear("Fix the login bug.")
        await settle { draft.text == "Fix the login bug." }

        #expect(draft.text == "Fix the login bug.")
        #expect(draft.selection == NSRange(location: 18, length: 0))
    }

    @Test func dictationLandsAtTheCaretAndKeepsTheTextAroundIt() async {
        let engine = ScriptedDictationEngine()
        let store = ComposerDictationStore(engine: engine)
        let draft = Draft("Please today", caret: 6)

        begin(store, in: draft)
        await settle { store.state == .listening }
        engine.hear("ship it")
        await settle { draft.text != "Please today" }

        #expect(draft.text == "Please ship it today")
        #expect(draft.selection == NSRange(location: 14, length: 0))
    }

    @Test func insertionSpacesWordsButNotExistingWhitespace() {
        let appended = ComposerDictationStore.Insertion(
            draft: "Hello", selection: NSRange(location: 5, length: 0))
        #expect(appended.applying("world").text == "Hello world")

        let afterNewline = ComposerDictationStore.Insertion(
            draft: "Hello\n", selection: NSRange(location: 6, length: 0))
        #expect(afterNewline.applying("world").text == "Hello\nworld")

        let replacing = ComposerDictationStore.Insertion(
            draft: "say old words", selection: NSRange(location: 4, length: 3))
        #expect(replacing.applying("new").text == "say new words")

        let outOfRange = ComposerDictationStore.Insertion(
            draft: "abc", selection: NSRange(location: 99, length: 4))
        #expect(outOfRange.applying("d").text == "abc d")

        #expect(appended.applying("").text == "Hello")
    }

    @Test func tappingAgainStopsAndReturnsToIdle() async {
        let engine = ScriptedDictationEngine()
        let store = ComposerDictationStore(engine: engine)
        let draft = Draft("")

        begin(store, in: draft)
        await settle { store.state == .listening }
        #expect(store.isActive)
        begin(store, in: draft)
        await settle { store.state == .idle }

        #expect(store.state == .idle)
        #expect(engine.startCount == 1)
        #expect(engine.stopCount == 1)
    }

    @Test(arguments: [
        DictationError.speechDenied, .microphoneDenied, .unavailable,
    ])
    func aRefusedStartSurfacesItsReason(error: DictationError) async {
        let engine = ScriptedDictationEngine()
        engine.startError = error
        let store = ComposerDictationStore(engine: engine)
        let draft = Draft("untouched")

        begin(store, in: draft)
        await settle { !store.isActive }

        #expect(store.state == .failed(error.message))
        #expect(store.failureMessage == error.message)
        #expect(draft.text == "untouched")
    }

    @Test func stoppingWhenIdleDoesNothing() {
        let engine = ScriptedDictationEngine()
        let store = ComposerDictationStore(engine: engine)

        store.stop()

        #expect(engine.stopCount == 0)
        #expect(store.state == .idle)
    }
}
