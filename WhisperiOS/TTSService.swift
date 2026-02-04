import AVFoundation

final class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var speakStartTime: DispatchTime?
    private var lastLatency: TimeInterval?
    private var onStart: ((TimeInterval) -> Void)?
    private var onFinish: ((TimeInterval, TimeInterval) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    func speak(_ text: String, onStart: @escaping (TimeInterval) -> Void, onFinish: @escaping (TimeInterval, TimeInterval) -> Void) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        self.onStart = onStart
        self.onFinish = onFinish
        speakStartTime = .now()

        let utterance = AVSpeechUtterance(string: text)
        let languageCode = Locale.current.language.languageCode?.identifier ?? "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard let startTime = speakStartTime else { return }
        let latency = Self.elapsedSeconds(since: startTime)
        lastLatency = latency
        onStart?(latency)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let startTime = speakStartTime else { return }
        let total = Self.elapsedSeconds(since: startTime)
        let latency = lastLatency ?? total
        onFinish?(latency, total)
        speakStartTime = nil
        lastLatency = nil
    }

    private static func elapsedSeconds(since start: DispatchTime) -> TimeInterval {
        let nanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return TimeInterval(Double(nanos) / 1_000_000_000)
    }
}
