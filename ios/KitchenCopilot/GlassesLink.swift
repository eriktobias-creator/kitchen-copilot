import Foundation
import MWDATCore
import MWDATInputs
import MWDATSpeech

/// Talks to the Oakley Meta glasses through Meta's Wearables Device Access
/// Toolkit (DAT):
///
/// - "Hey Meta, start Kitchen Copilot" opens the app (Voice Invocations).
/// - The glasses' own on-device speech recognition hears the wearer (Speech).
/// - The capture button press means "ask now" (Inputs).
///
/// Patterns follow Meta's BirdSpotter sample (samples/BirdSpotter in
/// facebook/meta-wearables-dat-ios, v1.0.1). Speech, Inputs and Voice
/// Invocations are experimental: they work with Developer Mode on for
/// personal use but can't be published yet.
@MainActor
final class GlassesLink {
    enum State: Equatable {
        case notRegistered, registering, waitingForGlasses, connecting, ready
        case problem(String)
    }

    var onState: ((State) -> Void)?
    /// Every transcription from the glasses mic, partial and final.
    var onTranscript: ((_ text: String, _ isFinal: Bool) -> Void)?
    /// Short press on the capture button.
    var onCapturePress: (() -> Void)?
    /// "Hey Meta, start Kitchen Copilot".
    var onLaunch: (() -> Void)?

    private(set) var state: State = .notRegistered {
        didSet { if state != oldValue { onState?(state) } }
    }
    var hearsGlasses: Bool { state == .ready && speech != nil }

    private var session: DeviceSession?
    private var speech: Speech?
    private var inputs: Inputs?
    private var sessionTokens = ListenerTokenBag()
    private var inputTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var watchTasks: [Task<Void, Never>] = []

    private var voiceStream: VoiceInvocationsStream?
    private var voiceTokens = ListenerTokenBag()
    private var voiceListeningOn: DeviceIdentifier?

    // MARK: - Setup

    /// Call once at launch, after `Wearables.configure()`.
    func start() {
        guard watchTasks.isEmpty else { return }

        watchTasks.append(Task { [weak self] in
            if case .registered = Wearables.shared.registrationState { self?.registered() }
            for await reg in Wearables.shared.registrationStateStream() {
                guard let self else { return }
                switch reg {
                case .registered: self.registered()
                case .registering: self.state = .registering
                default: self.state = .notRegistered
                }
            }
        })

        // Glasses appearing, connecting, or being put on: (re)open the session
        // and point the "Hey Meta" channel at them.
        watchTasks.append(Task { [weak self] in
            for await _ in Wearables.shared.devicesStream() {
                guard let self else { return }
                self.ensureVoiceChannel()
                self.openSessionIfNeeded()
            }
        })
    }

    /// Opens the Meta AI app to approve Kitchen Copilot. Needs Developer Mode
    /// on: Meta AI app > Settings > your glasses > Developer Mode.
    func register() async {
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            state = .problem(error.localizedDescription)
        }
    }

    /// Meta AI calls back into the app after registration/permission screens.
    static func handle(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
        else { return }
        Task { _ = try? await Wearables.shared.handleUrl(url) }
    }

    /// Asks Meta AI for the glasses microphone. Call from a button tap: it
    /// switches to the Meta AI app.
    func requestMicrophone() async {
        do {
            let status = try await Wearables.shared.requestPermission(.microphone)
            if status == .granted {
                closeSession()
                openSessionIfNeeded()
            } else {
                state = .problem("Glasses microphone not allowed. Use Connect glasses to try again.")
            }
        } catch {
            state = .problem(error.localizedDescription)
        }
    }

    private func registered() {
        if state == .notRegistered || state == .registering { state = .waitingForGlasses }
        startVoiceChannel()
        openSessionIfNeeded()
    }

    // MARK: - Device choice (same ranking as BirdSpotter)

    private static func rank(_ device: Device) -> Int {
        if device.linkState == .connected && device.donState == .donned { return 0 }
        if device.linkState == .connected { return 1 }
        if device.compatibility() == .compatible { return 2 }
        return 3
    }

    private static func preferredIdentifier() -> DeviceIdentifier? {
        Wearables.shared.devices
            .compactMap { Wearables.shared.deviceForIdentifier($0) }
            .min { rank($0) < rank($1) }?
            .identifier
    }

    // MARK: - "Hey Meta, start Kitchen Copilot"

    private func startVoiceChannel() {
        guard voiceStream == nil else { return }
        do {
            let stream = try VoiceInvocationsStream(wearables: Wearables.shared)
            voiceStream = stream
            stream.invocationsPublisher.listen { [weak self] invocation in
                Task { @MainActor in await self?.answer(invocation) }
            }.store(in: voiceTokens)
            stream.errorPublisher.listen { [weak self] _ in
                // Channel dropped; the next device change re-opens it.
                Task { @MainActor in self?.voiceListeningOn = nil }
            }.store(in: voiceTokens)
            ensureVoiceChannel()
        } catch {
            // Voice launch not approved for this app yet; everything else still works.
        }
    }

    private func ensureVoiceChannel() {
        guard let stream = voiceStream,
              let preferred = Self.preferredIdentifier(),
              preferred != voiceListeningOn else { return }
        if voiceListeningOn != nil { stream.stop() }
        voiceListeningOn = nil
        do {
            try stream.start(deviceIdentifier: preferred)
            voiceListeningOn = preferred
        } catch {
            // Link still coming up; the next device change asks again.
        }
    }

    private func answer(_ invocation: any VoiceInvocation) async {
        guard let launch = invocation as? LaunchApp else { return }
        // Every invocation must be answered exactly once.
        _ = await launch.responseHandle.sendSuccess(actionOutput: nil)
        openSessionIfNeeded()
        onLaunch?()
    }

    // MARK: - Session: speech + capture button

    private func openSessionIfNeeded() {
        guard sessionTask == nil else { return }
        guard case .registered = Wearables.shared.registrationState else { return }
        guard let identifier = Self.preferredIdentifier() else {
            state = .waitingForGlasses
            return
        }

        sessionTask = Task { [weak self] in
            await self?.runSession(on: identifier)
            guard let self else { return }
            self.closeSession()
            // Glasses folded, removed or out of range. Try again shortly; the
            // devices stream also re-triggers this when they come back.
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self.openSessionIfNeeded() }
        }
    }

    private func runSession(on identifier: DeviceIdentifier) async {
        state = .connecting
        let session: DeviceSession
        do {
            session = try Wearables.shared.createSession(
                deviceSelector: SpecificDeviceSelector(device: identifier)
            )
            self.session = session
            try session.start()
        } catch {
            state = .problem("Couldn't connect to the glasses: \(error.localizedDescription)")
            return
        }

        let errors = Task { [weak self] in
            for await error in session.errorStream() {
                if error == .datAppOnTheGlassesUpdateRequired {
                    self?.state = .problem("The glasses need an update in the Meta AI app.")
                    try? await Wearables.shared.openDATGlassesAppUpdate()
                }
            }
        }
        defer { errors.cancel() }

        for await sessionState in session.stateStream() {
            if Task.isCancelled { break }
            switch sessionState {
            case .started:
                await attachCapabilities(to: session)
            case .paused:
                state = .connecting
            case .stopped:
                return
            default:
                break
            }
        }
    }

    /// `started` means the session exists, not that the glasses are reachable
    /// yet; a capability attached too early fails and doesn't retry. So wait
    /// for the link first (BirdSpotter waits for camera frames instead).
    private func attachCapabilities(to session: DeviceSession) async {
        for _ in 0..<20 where session.device?.linkState != .connected {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .milliseconds(500))

        attachInputs(to: session)
        await attachSpeech(to: session)

        if speech != nil {
            state = .ready
        } else if inputs != nil {
            state = .problem("Glasses connected, but their mic isn't allowed. Tap Connect glasses.")
        } else {
            state = .problem("Glasses connected, but Speech and Inputs aren't enabled for this app in Wearables Developer Center.")
        }
    }

    private func attachInputs(to session: DeviceSession) {
        guard inputs == nil else { return }
        let configuration = InputsConfiguration(sources: [.captureButton], consumeBack: false)
        guard let attached = try? session.addInputs(configuration: configuration) else { return }
        inputs = attached
        let events = attached.events
        inputTask = Task { [weak self] in
            for await event in events {
                if case let .capture(pressType, source, _) = event,
                   pressType == .shortPress, source == .captureButton {
                    self?.onCapturePress?()
                }
            }
        }
    }

    private func attachSpeech(to session: DeviceSession) async {
        guard speech == nil else { return }
        // Only with the glasses-mic grant; without it, the phone mic is used.
        let granted = (try? await Wearables.shared.checkPermissionStatus(.microphone)) == .granted
        guard granted, let attached = try? session.addSpeech() else { return }
        speech = attached

        attached.transcriptionPublisher.listen { [weak self] result in
            let text = result.text
            let isFinal = result.isFinal
            Task { @MainActor in self?.onTranscript?(text, isFinal) }
        }.store(in: sessionTokens)

        // The recognizer can stop on its own (e.g. another experience takes the
        // glasses). Start it again, a few tries max, like BirdSpotter. Only a
        // recognizer that was started counts: it is also born `stopped`.
        speechHasStarted = false
        attached.statePublisher.listen { [weak self] speechState in
            Task { @MainActor in
                guard let self, self.speech != nil else { return }
                if speechState == .started { self.speechHasStarted = true }
                if speechState == .stopped, self.speechHasStarted { self.reviveSpeech() }
            }
        }.store(in: sessionTokens)

        attached.start()
    }

    private var speechHasStarted = false
    private var reviving = false

    private func reviveSpeech() {
        guard !reviving else { return }
        reviving = true
        Task { [weak self] in
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard let speech = self.speech, speech.state == .stopped else { break }
                speech.start()
            }
            self?.reviving = false
        }
    }

    private func closeSession() {
        inputTask?.cancel()
        inputTask = nil
        let old = sessionTokens
        sessionTokens = ListenerTokenBag()
        Task { await old.cancelAll() }
        if speech != nil { try? session?.removeSpeech() }
        if inputs != nil { try? session?.removeInputs() }
        speech = nil
        inputs = nil
        session?.stop()
        session = nil
        sessionTask = nil
        if case .problem = state { return }
        state = Self.preferredIdentifier() == nil ? .waitingForGlasses : .connecting
    }
}

extension GlassesLink.State {
    var label: String {
        switch self {
        case .notRegistered: "Not connected"
        case .registering: "Approving in Meta AI\u{2026}"
        case .waitingForGlasses: "Waiting for glasses"
        case .connecting: "Connecting\u{2026}"
        case .ready: "Ready"
        case .problem(let message): message
        }
    }
}
