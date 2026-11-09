import AudioToolbox
import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantViewModel {
    enum Status: Equatable {
        case setup, waiting, waitingGlasses, listening, thinking, speaking
        case problem(String)

        var label: String {
            switch self {
            case .setup: "Open Settings to connect"
            case .waiting: "Say \u{201C}Hey kitchen\u{201D}"
            case .waitingGlasses: "Press the capture button or say \u{201C}Hey kitchen\u{201D}"
            case .listening: "Listening\u{2026}"
            case .thinking: "Thinking\u{2026}"
            case .speaking: "Speaking"
            case .problem(let m): m
            }
        }
    }

    var status: Status = .setup
    var heard = ""
    var answer = ""
    var rush = false
    var history: [Turn] = []
    var route = AudioRouter.outputName
    var glassesState: GlassesLink.State = .notRegistered
    /// True when the glasses' own mic + speech recognition are in use.
    var usingGlasses = false

    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var token: String = Keychain.get("appToken") {
        didSet { Keychain.set(token, for: "appToken") }
    }

    let glasses = GlassesLink()
    private let listener = Listener()
    private var glassesCapturing = false
    private var glassesGiveUp: Task<Void, Never>?
    private let speaker = Speaker()
    private var current: Task<Void, Never>?
    private var started = false

    var isConfigured: Bool { URL(string: serverURL)?.scheme != nil && token.count >= 24 }

    func start() async {
        guard !started else { return }
        started = true

        listener.onWake = { [weak self] in
            guard let self else { return }
            self.speaker.stop()
            self.heard = ""
            self.status = .listening
            AudioServicesPlaySystemSound(1113) // short "listening" tone
        }
        listener.onPartial = { [weak self] in self?.heard = $0 }
        listener.onQuestion = { [weak self] q in self?.handle(question: q) }
        speaker.onFinished = { [weak self] in self?.backToWaiting() }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.route = AudioRouter.outputName }
        }

        // Phone/FaceTime calls take the mic away. Pause, then come back by
        // ourselves when the call ends.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began: self.pauseForCall()
                case .ended: await self.restartAudio()
                default: break
                }
            }
        }

        glasses.onState = { [weak self] state in self?.glassesStateChanged(state) }
        glasses.onTranscript = { [weak self] text, isFinal in self?.glassesHeard(text, isFinal: isFinal) }
        glasses.onCapturePress = { [weak self] in self?.tapToAsk() }
        glasses.onLaunch = { [weak self] in
            guard let self, self.status != .thinking, self.status != .speaking else { return }
            self.pauseEars()
            self.status = .speaking
            self.speaker.say("Kitchen Copilot is ready.")
        }
        glasses.start()

        guard await Listener.requestPermissions() else {
            status = .problem("Allow Microphone and Speech Recognition in iPhone Settings.")
            return
        }
        listener.onRestartFailed = { [weak self] error in
            self?.status = .problem(Self.friendly(error))
        }
        await restartAudio()
    }

    private func pauseForCall() {
        current?.cancel()
        speaker.stop()
        listener.stop()
        glassesCapturing = false
        status = .problem("Paused for a call. I'll start listening again when it ends.")
    }

    /// (Re)starts the mic and recognizer. Safe to call repeatedly.
    private func restartAudio() async {
        if usingGlasses {
            // The glasses hear us; the phone only needs to talk (A2DP, no
            // Bluetooth-mic format juggling).
            listener.stop()
            do {
                try AudioRouter.activatePlaybackOnly()
                route = AudioRouter.outputName
                status = isConfigured ? .waitingGlasses : .setup
            } catch {
                status = .problem(Self.friendly(error))
            }
            return
        }
        do {
            listener.stop()
            try AudioRouter.activate()
            try await listener.startWhenReady()
            route = AudioRouter.outputName
            status = isConfigured ? .waiting : .setup
        } catch {
            status = .problem(Self.friendly(error))
        }
    }

    private static func friendly(_ error: Error) -> String {
        let code = (error as NSError).code
        if code == AVAudioSession.ErrorCode.isBusy.rawValue
            || code == AVAudioSession.ErrorCode.insufficientPriority.rawValue
            || code == AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue {
            return "Another app or call is using the mic. End it, then tap the button."
        }
        return error.localizedDescription
    }

    /// Big button on screen: ask without the wake phrase, or stop talking.
    func tapToAsk() {
        if status == .speaking || status == .thinking {
            stopTalking()
        } else if usingGlasses {
            startGlassesCapture()
        } else if !listener.isRunning {
            Task { await restartAudio() } // e.g. after a call; tap again to ask
        } else {
            listener.captureNow()
        }
    }

    func stopTalking() {
        current?.cancel()
        speaker.stop()
        backToWaiting()
    }

    func startOver() {
        history.removeAll()
        heard = ""
        answer = ""
    }

    // MARK: - Flow

    private func handle(question: String) {
        heard = question
        if handleLocalCommand(question) { return }
        guard isConfigured, let url = URL(string: serverURL) else {
            status = .setup
            speaker.say("I'm not connected yet. Open settings on the phone.")
            return
        }

        pauseEars()
        status = .thinking
        answer = ""
        speaker.begin()

        let client = AssistantClient(baseURL: url, token: token)
        let prior = history
        current = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.ask(question: question, history: prior, rush: self.rush) {
                    switch event {
                    case .delta(let text):
                        if self.status == .thinking { self.status = .speaking }
                        self.answer += text
                        self.speaker.feed(text)
                    case .done:
                        break
                    }
                }
                self.history.append(Turn(role: .user, text: question))
                self.history.append(Turn(role: .assistant, text: self.answer))
                self.history = Array(self.history.suffix(40))
                self.status = .speaking
                self.speaker.finish()
            } catch {
                if Task.isCancelled { return } // user said stop
                let message = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach the server."
                self.status = .speaking
                self.speaker.say(message)
            }
        }
    }

    /// Voice commands handled on the phone, no server round trip.
    private func handleLocalCommand(_ q: String) -> Bool {
        let s = q.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let reply: String
        switch s {
        case "rush mode", "rush mode on", "turn on rush mode":
            rush = true; reply = "Rush mode on."
        case "rush mode off", "turn off rush mode", "normal mode":
            rush = false; reply = "Rush mode off."
        case "start over", "new shift", "clear":
            startOver(); reply = "Cleared."
        case "stop", "never mind", "nevermind", "cancel":
            stopTalking(); return true
        default:
            return false
        }
        pauseEars()
        status = .speaking
        speaker.say(reply)
        return true
    }

    private func backToWaiting() {
        if usingGlasses {
            status = isConfigured ? .waitingGlasses : .setup
        } else {
            status = isConfigured ? .waiting : .setup
            listener.resume()
        }
    }

    /// Stop listening while we think and talk, so we don't hear ourselves.
    private func pauseEars() {
        glassesCapturing = false
        glassesGiveUp?.cancel()
        if !usingGlasses { listener.pause() }
    }

    // MARK: - Glasses (Meta Wearables toolkit)

    private func glassesStateChanged(_ state: GlassesLink.State) {
        glassesState = state
        let nowUsing = glasses.hearsGlasses
        guard nowUsing != usingGlasses else { return }
        usingGlasses = nowUsing
        current?.cancel()
        speaker.stop()
        glassesCapturing = false
        Task { await restartAudio() }
    }

    /// Capture button (or the big button) while using the glasses mic.
    private func startGlassesCapture() {
        speaker.stop()
        heard = ""
        glassesCapturing = true
        status = .listening
        AudioServicesPlaySystemSound(1113)
        glassesGiveUp?.cancel()
        glassesGiveUp = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled, self.glassesCapturing, self.heard.isEmpty else { return }
            self.glassesCapturing = false
            self.backToWaiting()
        }
    }

    private func glassesHeard(_ text: String, isFinal: Bool) {
        // Ignore everything while thinking/speaking: the glasses mic can hear
        // our own answer coming out of the speakers.
        guard usingGlasses, status != .thinking, status != .speaking else { return }

        var question = text
        if !glassesCapturing {
            let lower = text.lowercased()
            guard let match = Listener.wakePhrases
                .compactMap({ lower.range(of: $0, options: .backwards) }).first
            else { return }
            let offset = lower.distance(from: lower.startIndex, to: match.upperBound)
            question = String(text.dropFirst(offset))
            if status != .listening {
                status = .listening
                AudioServicesPlaySystemSound(1113)
            }
        }
        question = question.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if !question.isEmpty {
            heard = question
            glassesGiveUp?.cancel()
        }
        guard isFinal else { return }

        if question.isEmpty {
            // "Hey kitchen" alone: the question comes in the next sentence.
            if !glassesCapturing { startGlassesCapture() }
            return
        }
        glassesCapturing = false
        handle(question: question)
    }
}
