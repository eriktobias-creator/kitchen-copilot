import AVFoundation
import Speech

/// Passes mic audio to the current recognition request. Lives on the audio
/// thread, so it is lock-protected instead of main-actor isolated.
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var muted = false

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); self.request = request; lock.unlock()
    }
    func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if !muted { request?.append(buffer) }
    }
}

/// Always-on, on-device speech recognition.
/// Hands-free: say "Hey kitchen, ..." and pause; the question ends after a
/// short silence. Tap-to-ask skips the wake phrase.
@MainActor
final class Listener {
    var onWake: (() -> Void)?
    var onPartial: ((String) -> Void)?
    var onQuestion: ((String) -> Void)?

    static let wakePhrases = ["hey kitchen", "okay kitchen", "ok kitchen", "hi kitchen"]
    /// Silence that ends a question. Kitchen talk has pauses; 1.4 s is a good start.
    var endOfQuestionSilence: TimeInterval = 1.4

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let sink = BufferSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    private var capturing = false
    private var captureOffset = 0
    private var latestQuestion = ""
    private var silenceTimer: Timer?
    private var giveUpTimer: Timer?
    private var refreshTimer: Timer?

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else { throw ListenerError.recognizerUnavailable }
        observeConfigChanges()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        // Use the mic's real hardware format. Glasses over Bluetooth run at
        // 16 kHz; the phone mic at 48 kHz. Using a stale format fails.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.micNotReady }
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()
        beginTask()
    }

    /// Starts, retrying while iOS finishes switching the audio route
    /// (e.g. to the glasses right after the session activates).
    func startWhenReady() async throws {
        var lastError: Error = ListenerError.micNotReady
        for delayMs in [300, 700, 1500] {
            try? await Task.sleep(for: .milliseconds(delayMs))
            do {
                stop()
                try start()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private var observingConfig = false
    private var restarting = false

    /// Glasses connecting/disconnecting changes the mic format; the engine
    /// stops itself and must be rebuilt.
    private func observeConfigChanges() {
        guard !observingConfig else { return }
        observingConfig = true
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.rebuildAfterConfigChange() }
        }
    }

    var onRestartFailed: ((Error) -> Void)?

    private func rebuildAfterConfigChange() async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        do {
            try await startWhenReady()
        } catch {
            onRestartFailed?(error)
        }
    }

    var isRunning: Bool { engine.isRunning }

    /// Fully release the mic, e.g. when a phone call takes over.
    func stop() {
        cancelCapture()
        refreshTimer?.invalidate()
        generation += 1
        task?.cancel()
        request?.endAudio()
        sink.set(nil)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Stop hearing ourselves while the answer is spoken.
    func pause() {
        sink.setMuted(true)
        cancelCapture()
    }

    func resume() {
        sink.setMuted(false)
        beginTask()
    }

    /// Tap-to-ask: start capturing immediately, no wake phrase needed.
    func captureNow() {
        sink.setMuted(false)
        beginTask()
        capturing = true
        captureOffset = 0
        onWake?()
        armGiveUp()
    }

    // MARK: - Recognition

    private func beginTask() {
        task?.cancel()
        request?.endAudio()
        generation += 1
        let gen = generation

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true // private, works on weak Wi-Fi
        }
        req.contextualStrings = Self.kitchenVocabulary + Self.wakePhrases
        req.taskHint = .search
        request = req
        sink.set(req)
        capturing = false
        captureOffset = 0
        latestQuestion = ""

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let text { self.handle(text) }
                if error != nil || isFinal {
                    if self.capturing { self.finishQuestion() } else { self.beginTask() }
                }
            }
        }

        // Long idle tasks drift and get slow; refresh them while waiting.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.generation, !self.capturing else { return }
                self.beginTask()
            }
        }
    }

    private func handle(_ transcript: String) {
        if !capturing {
            let lower = transcript.lowercased()
            guard let match = Self.wakePhrases.compactMap({ lower.range(of: $0, options: .backwards) }).first
            else { return }
            capturing = true
            captureOffset = lower.distance(from: lower.startIndex, to: match.upperBound)
            onWake?()
            armGiveUp()
        }

        let question = String(transcript.dropFirst(captureOffset))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !question.isEmpty else { return }
        latestQuestion = question
        onPartial?(question)
        giveUpTimer?.invalidate()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: endOfQuestionSilence, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishQuestion() }
        }
    }

    private func finishQuestion() {
        silenceTimer?.invalidate()
        giveUpTimer?.invalidate()
        let question = latestQuestion
        capturing = false
        if question.isEmpty {
            beginTask()
        } else {
            sink.setMuted(true)
            onQuestion?(question)
        }
    }

    /// Heard the wake phrase but no question followed.
    private func armGiveUp() {
        giveUpTimer?.invalidate()
        giveUpTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.latestQuestion.isEmpty else { return }
                self.cancelCapture()
                self.beginTask()
            }
        }
    }

    private func cancelCapture() {
        silenceTimer?.invalidate()
        giveUpTimer?.invalidate()
        capturing = false
        latestQuestion = ""
    }

    /// Helps recognition with words a generic model gets wrong in a kitchen.
    static let kitchenVocabulary = [
        "barbacoa", "carnitas", "sofritas", "chipotle", "pico", "pico de gallo", "guac", "guacamole",
        "queso", "queso blanco", "fajita veggies", "corn salsa", "tomatillo", "cilantro", "lime rice",
        "hotel pan", "sixth pan", "ninth pan", "third pan", "half pan", "backup", "make line",
        "digital make line", "DML", "expo", "grill", "prep", "dish pit", "walk-in", "sanitizer",
        "catering", "par", "par levels", "call-out", "Vanessa", "service leader", "rush mode",
    ]
}

enum ListenerError: LocalizedError {
    case recognizerUnavailable
    case micNotReady
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: "Speech recognition isn't available on this iPhone right now."
        case .micNotReady: "The microphone isn't ready. Tap the button to try again."
        }
    }
}
