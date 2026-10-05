import AVFoundation
import Speech

// SPDX-License-Identifier: Apache-2.0

/// Dictation through Apple's Speech framework, on device where the language
/// supports it. Recording borrows the shared audio session; when it ends the
/// session returns to silent playback and ``audioSessionReleased`` tells the
/// Background Alerts keep-alive to resume.
@MainActor
final class SpeechDictationEngine: DictationEngine {
    static let audioSessionReleased = Notification.Name("SpeechDictationEngine.audioSessionReleased")

    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() async throws -> AsyncStream<String> {
        guard await Self.requestSpeechAuthorization() else { throw DictationError.speechDenied }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw DictationError.microphoneDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable
        else { throw DictationError.unavailable }
        tearDown()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition

            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw DictationError.unavailable
            }
            Self.installTap(on: engine.inputNode, format: format, feeding: request)
            engine.prepare()
            try engine.start()

            let (stream, continuation) = AsyncStream<String>.makeStream()
            audioEngine = engine
            self.request = request
            task = Self.recognize(request, with: recognizer, into: continuation) { [weak self] in
                Task { @MainActor in self?.tearDown() }
            }
            return stream
        } catch {
            tearDown()
            throw DictationError.unavailable
        }
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
    }

    private func tearDown() {
        guard audioEngine != nil || task != nil else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        task?.cancel()
        audioEngine = nil
        request = nil
        task = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        NotificationCenter.default.post(name: Self.audioSessionReleased, object: nil)
    }

    // The framework calls these blocks on its own queues. They are formed in
    // nonisolated functions so they do not inherit the main actor, which
    // Swift 6 would otherwise assert at run time.

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private nonisolated static func installTap(
        on node: AVAudioInputNode,
        format: AVAudioFormat,
        feeding request: SFSpeechAudioBufferRecognitionRequest
    ) {
        nonisolated(unsafe) let request = request
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        with recognizer: SFSpeechRecognizer,
        into continuation: AsyncStream<String>.Continuation,
        onFinish: @escaping @Sendable () -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                continuation.yield(result.bestTranscription.formattedString)
            }
            if error != nil || result?.isFinal == true {
                continuation.finish()
                onFinish()
            }
        }
    }
}
