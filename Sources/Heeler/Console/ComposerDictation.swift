import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0

enum DictationError: Error, Equatable {
    case speechDenied
    case microphoneDenied
    case unavailable

    var message: String {
        switch self {
        case .speechDenied:
            "Allow Speech Recognition for Heeler in Settings to dictate."
        case .microphoneDenied:
            "Allow the microphone for Heeler in Settings to dictate."
        case .unavailable:
            "Dictation is not available right now."
        }
    }
}

/// The speech recogniser behind the Composer's Dictate button. A seam so the
/// store is tested against a scripted engine: the Simulator cannot recognise
/// speech.
@MainActor
protocol DictationEngine: AnyObject {
    /// Starts listening. Each element is the whole transcript so far, not an
    /// increment; the stream ends when recognition does.
    func start() async throws -> AsyncStream<String>
    /// Stops listening. The stream delivers any final transcript, then ends.
    func stop()
}

/// Dictates into the Composer draft. The transcript replaces the selection
/// the draft had when dictation began and grows in place as the recogniser
/// revises it; text on either side is kept.
@MainActor
@Observable
final class ComposerDictationStore {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private let engine: any DictationEngine
    @ObservationIgnored private var session: Task<Void, Never>?

    init(engine: any DictationEngine) {
        self.engine = engine
    }

    var isActive: Bool {
        state == .starting || state == .listening
    }

    var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    /// Starts dictation at `selection`, or stops the dictation in progress.
    func toggle(
        draft: String,
        selection: NSRange,
        apply: @escaping (String, NSRange) -> Void
    ) {
        guard !isActive else {
            stop()
            return
        }
        state = .starting
        let insertion = Insertion(draft: draft, selection: selection)
        session = Task { [weak self, engine] in
            do {
                let transcripts = try await engine.start()
                guard let self, self.state == .starting else {
                    engine.stop()
                    return
                }
                self.state = .listening
                for await transcript in transcripts {
                    let (text, caret) = insertion.applying(transcript)
                    apply(text, caret)
                }
                self.state = .idle
            } catch let error as DictationError {
                self?.state = .failed(error.message)
            } catch {
                self?.state = .failed(DictationError.unavailable.message)
            }
        }
    }

    func stop() {
        guard isActive else { return }
        if state == .starting {
            state = .idle
        }
        engine.stop()
    }

    /// Where a transcript lands in the draft it was started in.
    struct Insertion: Equatable {
        let prefix: String
        let suffix: String

        init(draft: String, selection: NSRange) {
            let text = draft as NSString
            let start = min(max(0, selection.location), text.length)
            let end = min(max(start, selection.location + selection.length), text.length)
            prefix = text.substring(to: start)
            suffix = text.substring(from: end)
        }

        func applying(_ transcript: String) -> (text: String, caret: NSRange) {
            guard !transcript.isEmpty else {
                return (prefix + suffix, NSRange(location: (prefix as NSString).length, length: 0))
            }
            let leading = prefix.last.map { !$0.isWhitespace } ?? false ? " " : ""
            let trailing = suffix.first.map { !$0.isWhitespace } ?? false ? " " : ""
            let head = prefix + leading + transcript
            return (
                head + trailing + suffix,
                NSRange(location: (head as NSString).length, length: 0)
            )
        }
    }
}
