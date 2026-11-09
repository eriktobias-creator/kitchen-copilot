import AVFoundation

/// Speaks the answer sentence by sentence while it is still streaming in,
/// so you hear the first words in about a second instead of waiting for the
/// whole reply.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?
    var rate: Float = 0.52 // a bit faster than default; tune in Settings

    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    /// Utterances queued but not yet finished; tracked by identity so a late
    /// callback from a stopped answer can't end the current one early.
    private var queued = Set<ObjectIdentifier>()
    private var streamEnded = false
    private let voice: AVSpeechSynthesisVoice? = Speaker.bestVoice()

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
    }

    var isSpeaking: Bool { !queued.isEmpty || synth.isSpeaking }

    func begin() {
        stop()
        streamEnded = false
    }

    func feed(_ text: String) {
        buffer += text
        while let end = Self.sentenceEnd(in: buffer) {
            let sentence = String(buffer[..<end])
            buffer = String(buffer[end...])
            speak(sentence)
        }
    }

    func finish() {
        streamEnded = true
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { speak(buffer) }
        buffer = ""
        if queued.isEmpty { onFinished?() }
    }

    func say(_ text: String) {
        begin()
        feed(text)
        finish()
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        buffer = ""
        queued.removeAll()
    }

    private func speak(_ text: String) {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = voice
        utterance.rate = rate
        utterance.postUtteranceDelay = 0.05
        queued.insert(ObjectIdentifier(utterance))
        synth.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard queued.remove(id) != nil else { return } // from a stopped answer
        if queued.isEmpty && streamEnded { onFinished?() }
    }

    /// End of the first complete sentence: . ! ? or newline followed by space.
    static func sentenceEnd(in text: String) -> String.Index? {
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\n" { return next }
            if ".!?".contains(c), next < text.endIndex, text[next].isWhitespace {
                // Needs whitespace after, so "1.5" is never split.
                return next
            }
            i = next
        }
        return nil
    }

    /// Strips markdown the model might still slip in.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "- ", with: "")
            .replacingOccurrences(of: "°F", with: " degrees")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefers a Premium or Enhanced voice if downloaded:
    /// Settings > Accessibility > Spoken Content > Voices > English.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}
