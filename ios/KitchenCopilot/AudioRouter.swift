import AVFoundation

/// Routes mic + speaker to the glasses. Oakley Meta / Ray-Ban Meta glasses
/// pair with the iPhone as a Bluetooth headset, so a voice-chat audio session
/// with Bluetooth HFP allowed uses their mics and open-ear speakers. If the
/// glasses aren't connected, it falls back to the phone's speaker.
enum AudioRouter {
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat, // echo cancellation + noise suppression for a loud kitchen
            options: [.allowBluetooth, .defaultToSpeaker, .duckOthers]
        )
        try session.setActive(true)
    }

    static var outputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "None"
    }

    static var isOnBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
        }
    }
}
