import AVFoundation
import WhisperKit

struct WhisperTranscriptionResult {
    let text: String
    let processingTime: TimeInterval
    let audioDuration: TimeInterval
    let realTimeFactor: Double?
}

enum WhisperEngineError: LocalizedError {
    case modelMissing
    case tokenizerMissing
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "Whisper model folder not found in the app bundle."
        case .tokenizerMissing:
            return "Tokenizer files not found in the app bundle."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

protocol WhisperTranscribing {
    func transcribe(audioURL: URL) async throws -> WhisperTranscriptionResult
}

final class WhisperEngine: WhisperTranscribing {
    private var whisperKit: WhisperKit?
    private var streamTranscriber: StreamingTranscriber?
    private let modelFolderURL: URL?
    private let tokenizerFolderURL: URL?

    init(
        modelFolderURL: URL? = Bundle.main.url(
            forResource: "openai_whisper-tiny",
            withExtension: nil
        ),
        tokenizerFolderURL: URL? = Bundle.main.url(
            forResource: "openai-whisper-tiny",
            withExtension: nil
        )
    ) {
        self.modelFolderURL = modelFolderURL
        self.tokenizerFolderURL = tokenizerFolderURL
    }

    func transcribe(audioURL: URL) async throws -> WhisperTranscriptionResult {
        guard let modelFolderURL else {
            throw WhisperEngineError.modelMissing
        }
        guard let tokenizerFolderURL else {
            throw WhisperEngineError.tokenizerMissing
        }

        let whisperKit = try await loadWhisperKit(modelFolderURL: modelFolderURL, tokenizerFolderURL: tokenizerFolderURL)
        let audioDuration = try Self.audioDuration(for: audioURL)
        let start = Date()

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )

        do {
            let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)
            let combinedText = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let timings = results.first?.timings
            let processingTime = timings?.fullPipeline ?? Date().timeIntervalSince(start)
            let realTimeFactor = timings?.realTimeFactor

            return WhisperTranscriptionResult(
                text: combinedText,
                processingTime: processingTime,
                audioDuration: audioDuration,
                realTimeFactor: realTimeFactor
            )
        } catch {
            throw WhisperEngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    func startStreaming(
        config: StreamingConfig,
        stateHandler: @escaping (StreamingState) -> Void
    ) async throws {
        guard let modelFolderURL else {
            throw WhisperEngineError.modelMissing
        }
        guard let tokenizerFolderURL else {
            throw WhisperEngineError.tokenizerMissing
        }

        if let existing = streamTranscriber {
            await existing.stop()
            streamTranscriber = nil
        }

        let whisperKit = try await loadWhisperKit(modelFolderURL: modelFolderURL, tokenizerFolderURL: tokenizerFolderURL)
        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperEngineError.tokenizerMissing
        }

        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: nil,
            temperature: 0.0,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false
        )

        let transcriber = StreamingTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: options,
            config: config,
            stateChangeCallback: { _, newState in
                stateHandler(newState)
            }
        )

        streamTranscriber = transcriber
        try await transcriber.start()
    }

    func stopStreaming() async {
        guard let transcriber = streamTranscriber else { return }
        await transcriber.stop()
        streamTranscriber = nil
    }

    private func loadWhisperKit(modelFolderURL: URL, tokenizerFolderURL: URL) async throws -> WhisperKit {
        if let whisperKit { return whisperKit }

        let config = WhisperKitConfig(
            model: "tiny",
            modelFolder: modelFolderURL.path,
            tokenizerFolder: tokenizerFolderURL,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        return kit
    }

    private static func audioDuration(for url: URL) throws -> TimeInterval {
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(Double(audioFile.length) / sampleRate)
    }
}
