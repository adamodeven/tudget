import AVFoundation
import Speech
import SwiftUI

/// Hold-to-talk dictation for the capture bar.
///
/// The whole point of the capture bar is that logging a purchase costs one
/// gesture, and a keyboard is four -- unlock, tap, type, tap. Holding a button
/// and saying "eleven fifty at Blue Bottle" is one. So the mic opens on the
/// press and closes on the release, and nothing reaches the ledger until
/// you've seen what was heard.
///
/// Recognition is asked to stay on the device: a purchase is nobody else's
/// business, and the rest of the app already works with the network off. Only
/// a phone with no on-device model for the current locale falls back to
/// Apple's servers.
@MainActor
@Observable
final class VoiceCapture {

    /// Where a hold currently is -- which is also exactly what the listening
    /// overlay draws.
    enum Phase: Equatable {
        case idle
        /// The mic is open and `transcript` grows as you speak.
        case listening
        /// You let go, and the recognizer still owes us its final pass.
        case settling
    }

    /// What a completed hold produced.
    enum Outcome: Equatable {
        case heard(String)
        /// The hold was long enough, but nothing came back.
        case nothingHeard
        /// The first hold spent itself on the permission prompts. Nothing was
        /// recorded and nothing is wrong -- they just need to hold again.
        case askedForPermission
        /// Permission, hardware, or the recognizer said no. Carries a sentence
        /// worth showing someone rather than an error code.
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    /// Smoothed 0...1 microphone level, so the overlay can show that it really
    /// is hearing something.
    private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set from the recognition callback once the last pass is in.
    private var hasFinalResult = false

    /// Bumped by anything that ends a hold. `start` is asynchronous -- it can
    /// still be waiting on a permission prompt when the finger comes up -- so
    /// it checks this before opening the mic rather than leaving one open with
    /// nobody holding the button.
    private var generation = 0

    var isBusy: Bool { phase != .idle }

    // MARK: - The hold

    /// Opens the mic. Returns nil once we're listening, or the outcome that
    /// stopped us from getting there.
    ///
    /// `hints` are words to lean towards -- the user's own category names and
    /// the places they shop, which are exactly the words a general dictation
    /// model is worst at.
    func start(hints: [String] = []) async -> Outcome? {
        guard phase == .idle else { return nil }

        let mine = generation
        transcript = ""
        level = 0
        hasFinalResult = false

        switch await Self.authorize() {
        case .refused(let reason):
            return .unavailable(reason)
        case .allowedAfterPrompting:
            // Two system dialogs have been and gone; whatever they were
            // holding the button for is long over.
            return .askedForPermission
        case .allowed:
            break
        }

        guard mine == generation, phase == .idle else { return nil }

        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            return .unavailable("Speech recognition isn't available on this phone right now.")
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        // Punctuation would only be something the parser has to strip off again.
        request.addsPunctuation = false
        request.contextualStrings = Array(hints.prefix(100))
        self.request = request

        do {
            try openMicrophone(feeding: request)
        } catch {
            teardown()
            return .unavailable("I couldn't open the microphone just then.")
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let finished = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                if let text { self.transcript = text }
                if finished { self.hasFinalResult = true }
            }
        }

        phase = .listening
        return nil
    }

    /// Closes the mic and waits, briefly, for the words said last.
    func finish() async -> Outcome {
        generation += 1

        guard phase == .listening else {
            teardown()
            return .nothingHeard
        }
        phase = .settling

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        // The tail of a sentence lands after the audio does, so give the
        // recognizer a moment before settling for whatever partial we have.
        // Polled rather than awaited on a continuation because the callback
        // fires repeatedly, and resuming a continuation twice is a crash.
        let deadline = Date.now.addingTimeInterval(1.2)
        while !hasFinalResult, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        return heard.isEmpty ? .nothingHeard : .heard(heard)
    }

    /// Throws the hold away -- used when the press turns out to be a swipe.
    func cancel() {
        generation += 1
        teardown()
    }

    // MARK: - Audio

    private func openMicrophone(feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(
            onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)
        ) { [weak self] buffer, _ in
            request.append(buffer)
            self?.report(levelOf: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// Called on the audio thread, so it does its arithmetic there and hops to
    /// the main actor only to hand over one number.
    nonisolated private func report(levelOf buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()

        // Speech sits well below full scale; this gain puts a normal speaking
        // voice across most of the bar without a loud room pinning it there.
        let scaled = Double(min(1, rms * 12))

        Task { @MainActor in
            self.level += (scaled - self.level) * 0.35
        }
    }

    /// Safe to call in any state, and safe to call twice.
    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil

        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }

        transcript = ""
        level = 0
        hasFinalResult = false
        phase = .idle
    }

    // MARK: - Permission

    private enum Authorization {
        case allowed
        /// Allowed, but only after showing the system prompts just now.
        case allowedAfterPrompting
        case refused(String)
    }

    /// Speech recognition and the microphone are two separate grants, and iOS
    /// asks for each exactly once ever -- so a refusal is reported rather than
    /// retried, with the Settings path spelled out.
    private static func authorize() async -> Authorization {
        let hadBeenAsked = SFSpeechRecognizer.authorizationStatus() != .notDetermined
            && AVAudioApplication.shared.recordPermission != .undetermined

        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            return .refused(
                "Tudget needs permission for speech recognition to hear a purchase. "
                + "Turn it on in Settings › Tudget › Speech Recognition."
            )
        }

        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else {
            return .refused(
                "Tudget needs the microphone to hear a purchase. "
                + "Turn it on in Settings › Tudget › Microphone."
            )
        }

        return hadBeenAsked ? .allowed : .allowedAfterPrompting
    }
}
