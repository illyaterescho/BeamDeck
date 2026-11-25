#if os(iOS)
import AVFoundation
import Speech

/// Push-to-talk Ukrainian speech recognition. Prefers on-device recognition when iOS has the language pack.
@MainActor
final class VoiceControl: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""
    @Published private(set) var problem: String?
    @Published private(set) var onDevice = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "uk-UA"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished: CheckedContinuation<Void, Never>?
    /// False once the button is released, so a slow permission prompt cannot start listening afterwards.
    private var wanted = false

    /// Words the recognizer would otherwise mishear.
    private static let hints = ["ютуб", "нетфлікс", "дісней", "автофокус", "трапеція", "фокус ближче", "фокус далі",
                                "гучніше", "тихіше", "без звуку", "вгору", "вниз", "ліворуч", "праворуч", "на головну",
                                "знайди", "напиши", "проєктор", "пауза", "наступне", "попереднє"]

    func start() async {
        guard !listening else { return }
        wanted = true
        problem = nil
        transcript = ""
        guard await authorize(), wanted else { return }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Розпізнавання української зараз недоступне. Перевірте інтернет або мову Siri."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.contextualStrings = Self.hints
            onDevice = recognizer.supportsOnDeviceRecognition
            if onDevice { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || result?.isFinal == true
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.finished?.resume(); self.finished = nil }
                }
            }
        } catch {
            problem = "Не вдалося увімкнути мікрофон."
            teardown()
        }
    }

    /// Stops listening and waits briefly for the final transcript.
    func finish() async -> String {
        wanted = false
        guard listening else { return transcript }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        listening = false
        await withCheckedContinuation { continuation in
            finished = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                self.finished?.resume()
                self.finished = nil
            }
        }
        teardown()
        return transcript
    }

    func cancel() {
        wanted = false
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        listening = false
        teardown()
    }

    private func teardown() {
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            problem = "Дозвольте BeamDeck розпізнавання мовлення: Налаштування → BeamDeck."
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Дозвольте BeamDeck доступ до мікрофона: Налаштування → BeamDeck."
            return false
        }
        return true
    }
}
#endif
