import AVFoundation
import ScreenCoachCore
import Speech

/// Push-to-talk speech in, spoken answers out. Entirely on-device.
///
/// The microphone runs only between `begin()` and `end()` — while the key is
/// physically held. No always-on listening, no wake word, no permanent
/// recording indicator, and nothing to leave the machine. For an app that
/// already needs permission to read your screen, an always-live microphone is
/// one ask too many.
///
/// `requiresOnDeviceRecognition` is set whenever the locale supports it, which
/// makes "zero bytes leave the machine" a property of the code rather than a
/// claim in a README. When the locale has no on-device model the recogniser
/// would fall back to Apple's servers, so this refuses instead and says why.
public final class Voice: NSObject {

    public enum Availability: Equatable {
        case ready(onDevice: Bool)
        case needsPermission(String)
        case unavailable(String)
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var delivered = false
    private var startedAtNs: UInt64 = 0

    /// Live transcript while the key is held.
    public var onPartial: ((String) -> Void)?
    /// The finished utterance, with the milliseconds from key-release to final
    /// text — the STT term of the latency budget.
    public var onFinal: ((String, Double) -> Void)?
    public var onState: ((String) -> Void)?

    /// Refuse to send audio off-device. If the recogniser cannot work locally
    /// the feature is off, not silently remote.
    public var localOnly = true

    public private(set) var isListening = false

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Permissions

    public static var permissionSummary: String {
        func name(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
            switch s {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not asked"
            @unknown default: return "unknown"
            }
        }
        func mic(_ s: AVAuthorizationStatus) -> String {
            switch s {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not asked"
            @unknown default: return "unknown"
            }
        }
        return "speech \(name(SFSpeechRecognizer.authorizationStatus())), "
             + "mic \(mic(AVCaptureDevice.authorizationStatus(for: .audio)))"
    }

    public var availability: Availability {
        guard let recognizer else { return .unavailable("no recogniser for this locale") }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            return .needsPermission("Speech Recognition")
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            return .needsPermission("Microphone")
        }
        guard recognizer.isAvailable else { return .unavailable("recogniser unavailable") }
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            return .unavailable("no on-device model for this locale — "
                              + "voice is off rather than sending audio to a server")
        }
        return .ready(onDevice: recognizer.supportsOnDeviceRecognition)
    }

    /// Asks for both permissions up front rather than mid-utterance. Being
    /// interrupted by a dialog while holding a key to speak loses the turn.
    public func requestPermissions(_ done: @escaping (Availability) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { done(self?.availability ?? .unavailable("gone")) }
            }
        }
    }

    // MARK: - Listening

    public func begin() {
        guard !isListening else { return }
        guard case .ready = availability else {
            onState?(describe(availability))
            return
        }
        guard let recognizer else { return }

        transcript = ""
        delivered = false

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            onState?("no usable microphone input")
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onState?("could not start the microphone: \(error.localizedDescription)")
            return
        }

        isListening = true
        onState?("listening")
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.onPartial?(self.transcript)
                    if result.isFinal { self.deliver() }
                }
                if error != nil && !self.engine.isRunning { self.deliver() }
            }
        }
    }

    /// Key released. Stop capturing immediately — the microphone must not
    /// outlive the hold by even a moment — then wait briefly for the
    /// recogniser to finalise what it already heard.
    public func end() {
        guard isListening else { return }
        isListening = false
        startedAtNs = Mono.nowNs()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()

        // Finalisation is usually tens of milliseconds, but a recogniser that
        // never calls back would otherwise lose the turn silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.deliver()
        }
    }

    public func cancel() {
        isListening = false
        delivered = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        task?.cancel()
        task = nil
        request = nil
    }

    private func deliver() {
        guard !delivered else { return }
        delivered = true
        task = nil
        request = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let ms = startedAtNs == 0 ? 0 : Mono.msSince(startedAtNs)
        guard !text.isEmpty else {
            onState?("didn't catch that")
            return
        }
        onFinal?(text, ms)
    }

    // MARK: - Speaking

    /// `AVSpeechSynthesizer`, on-device and free. Cloud voices sound better,
    /// but a coach whose answers require a network round trip is a coach that
    /// stops working on a plane — and every byte spoken here is a description
    /// of the user's own screen.
    public func speak(_ text: String) {
        guard !text.isEmpty else { return }
        stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.postUtteranceDelay = 0
        if let voice = AVSpeechSynthesisVoice(identifier: AVSpeechSynthesisVoiceIdentifierAlex)
            ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    public func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func describe(_ a: Availability) -> String {
        switch a {
        case .ready: return "ready"
        case .needsPermission(let what): return "\(what) permission needed"
        case .unavailable(let why): return why
        }
    }
}

extension Voice: AVSpeechSynthesizerDelegate {}
