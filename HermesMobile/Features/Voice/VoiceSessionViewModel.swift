import AVFoundation
import Foundation
import Observation
import Speech

struct VoiceTurn: Identifiable {
    let id = UUID()
    let user: String
    let assistant: String
}

@MainActor
@Observable
final class VoiceSessionViewModel {
    enum Phase: Equatable {
        case idle
        case listening
        case sending
        case streaming
        case speaking
        case error(String)

        var statusLabel: String {
            switch self {
            case .idle: return "Tap to speak"
            case .listening: return "Listening\u{2026}"
            case .sending, .streaming: return "Thinking\u{2026}"
            case .speaking: return "Speaking\u{2026}"
            case .error(let msg): return msg
            }
        }

        var isMicActive: Bool {
            if case .listening = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .sending, .streaming: return true
            default: return false
            }
        }

        var isSpeaking: Bool {
            if case .speaking = self { return true }
            return false
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var turns: [VoiceTurn] = []
    private(set) var currentResponseText = ""
    private(set) var liveTranscript = ""

    private let client: APIClient
    private var sessionID: String?
    private let sseClient = SSEClient()

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var audioPlayer: ServerTTSAudioPlayer?
    private var onDeviceSynthesizer: AVSpeechSynthesizer?
    private var synthDelegate: VoiceSynthesizerDelegate?
    private let audioSession = ListenAudioSessionController()

    init(server: URL) {
        client = APIClient(baseURL: server)
    }

    func tapMic() async {
        switch phase {
        case .idle, .error:
            await startListening()
        case .listening:
            let text = liveTranscript
            stopRecording()
            await send(text: text)
        case .speaking:
            skipSpeaking()
            phase = .idle
        case .sending, .streaming:
            break
        }
    }

    func close() {
        sseClient.stop()
        skipSpeaking()
        stopRecording()
        phase = .idle
    }

    // MARK: - Recording

    private func startListening() async {
        liveTranscript = ""
        phase = .listening

        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard case .listening = phase else { return }
        guard speechStatus == .authorized else {
            setError("Speech recognition is not authorized. Enable it in Settings.")
            return
        }

        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
        guard case .listening = phase else { return }
        guard micGranted else {
            setError("Microphone access is required. Enable it in Settings.")
            return
        }

        do {
            try beginRecording()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func beginRecording() throws {
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw VoiceSessionError.speechUnavailable
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine

        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        ComposerAudioCaptureState.shared.setCapturing(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        engine.prepare()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, case .listening = self.phase else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let text = self.liveTranscript
                        self.stopRecording()
                        await self.send(text: text)
                        return
                    }
                }
                if error != nil {
                    // Normal end-of-speech sometimes fires an error; use whatever
                    // transcript we have rather than discarding it.
                    let text = self.liveTranscript
                    self.stopRecording()
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        await self.send(text: text)
                    } else {
                        self.phase = .idle
                    }
                }
            }
        }

        try engine.start()
    }

    private func stopRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            audioEngine = nil
        }
        speechRecognizer = nil
        ComposerAudioCaptureState.shared.setCapturing(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Send + Stream

    private func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }

        phase = .sending

        do {
            if sessionID == nil {
                let response = try await client.createSession(
                    workspace: nil,
                    model: nil,
                    modelProvider: nil,
                    profile: nil
                )
                guard let id = response.session?.sessionId else {
                    setError("Could not create a session.")
                    return
                }
                sessionID = id
            }

            guard let sessionID else { return }

            let chatResponse = try await client.startChat(
                sessionID: sessionID,
                message: trimmed,
                workspace: nil,
                model: nil
            )

            guard let streamID = chatResponse.streamId else {
                setError(chatResponse.error ?? "Could not start chat.")
                return
            }

            currentResponseText = ""
            phase = .streaming

            let streamURL = client.chatStreamURL(streamID: streamID)
            sseClient.start(url: streamURL) { [weak self] event in
                guard let self else { return }
                switch event {
                case .token(let t):
                    self.currentResponseText += t
                case .done:
                    self.sseClient.stop()
                    let response = self.currentResponseText
                    self.turns.append(VoiceTurn(user: trimmed, assistant: response))
                    self.currentResponseText = ""
                    Task { await self.speakResponse(response) }
                case .error(let msg):
                    self.sseClient.stop()
                    self.setError(msg)
                case .cancelled, .transportError:
                    self.sseClient.stop()
                    self.phase = .idle
                default:
                    break
                }
            }
        } catch {
            setError(error.localizedDescription)
        }
    }

    // MARK: - TTS

    private func speakResponse(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .idle
            return
        }
        phase = .speaking

        if ServerTTSPolicy.shouldUseServerTTS(for: text) {
            do {
                let audioData = try await client.synthesizeSpeech(
                    text: text,
                    voice: ServerTTSPolicy.defaultVoice
                )
                let player = try ServerTTSAudioPlayer(data: audioData)
                audioPlayer = player
                player.onFinish = { [weak self] in
                    self?.audioPlayer = nil
                    self?.audioSession.deactivate()
                    self?.phase = .idle
                }
                audioSession.activate()
                if player.play() { return }
                audioPlayer = nil
                audioSession.deactivate()
            } catch {
                // Server TTS failed; fall through to on-device.
            }
        }

        speakOnDevice(text)
    }

    private func speakOnDevice(_ text: String) {
        let delegate = VoiceSynthesizerDelegate()
        delegate.onFinish = { [weak self] in
            self?.synthDelegate = nil
            self?.onDeviceSynthesizer = nil
            if case .speaking = self?.phase { self?.phase = .idle }
        }
        synthDelegate = delegate

        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = delegate
        onDeviceSynthesizer = synthesizer

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func skipSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioSession.deactivate()
        onDeviceSynthesizer?.stopSpeaking(at: .immediate)
        onDeviceSynthesizer = nil
        synthDelegate = nil
    }

    // MARK: - Error

    private func setError(_ message: String) {
        phase = .error(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, case .error = self.phase else { return }
            self.phase = .idle
        }
    }
}

/// NSObject delegate bridge for `AVSpeechSynthesizer`. Held alongside the
/// synthesizer so neither outlives the other.
@MainActor
final class VoiceSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (@MainActor () -> Void)?

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.onFinish?() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.onFinish?() }
    }
}

private enum VoiceSessionError: LocalizedError {
    case speechUnavailable

    var errorDescription: String? {
        "Speech recognition is not available for the current locale."
    }
}
