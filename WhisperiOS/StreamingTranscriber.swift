import Foundation
import WhisperKit

struct StreamingConfig {
    var minBufferSeconds: Double
    var requiredSegmentsForConfirmation: Int
    var silenceThreshold: Float
    var compressionCheckWindow: Int
    var useVAD: Bool
}

struct StreamingState {
    var isRecording: Bool = false
    var currentFallbacks: Int = 0
    var lastBufferSize: Int = 0
    var lastConfirmedSegmentEndSeconds: Float = 0
    var bufferEnergy: [Float] = []
    var currentText: String = ""
    var confirmedSegments: [TranscriptionSegment] = []
    var unconfirmedSegments: [TranscriptionSegment] = []
    var unconfirmedText: [String] = []
}

typealias StreamingStateCallback = (StreamingState, StreamingState) -> Void

/// Lightweight streaming wrapper to allow adjustable buffering thresholds.
actor StreamingTranscriber {
    private var state: StreamingState = .init() {
        didSet {
            stateChangeCallback?(oldValue, state)
        }
    }

    private let stateChangeCallback: StreamingStateCallback?
    private let config: StreamingConfig
    private let transcribeTask: TranscribeTask
    private let audioProcessor: any AudioProcessing
    private let decodingOptions: DecodingOptions

    init(
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer,
        audioProcessor: any AudioProcessing,
        decodingOptions: DecodingOptions,
        config: StreamingConfig,
        stateChangeCallback: StreamingStateCallback?
    ) {
        self.transcribeTask = TranscribeTask(
            currentTimings: TranscriptionTimings(),
            progress: Progress(),
            audioProcessor: audioProcessor,
            audioEncoder: audioEncoder,
            featureExtractor: featureExtractor,
            segmentSeeker: segmentSeeker,
            textDecoder: textDecoder,
            tokenizer: tokenizer
        )
        self.audioProcessor = audioProcessor
        self.decodingOptions = decodingOptions
        self.config = config
        self.stateChangeCallback = stateChangeCallback
    }

    func start() async throws {
        guard !state.isRecording else { return }
        state.isRecording = true
        try audioProcessor.startRecordingLive { [weak self] _ in
            Task { [weak self] in
                await self?.onAudioBufferCallback()
            }
        }
        await realtimeLoop()
    }

    func stop() {
        state.isRecording = false
        audioProcessor.stopRecording()
    }

    private func realtimeLoop() async {
        while state.isRecording {
            do {
                try await transcribeCurrentBuffer()
            } catch {
                Logging.error("Streaming error: \(error.localizedDescription)")
                break
            }
        }
    }

    private func onAudioBufferCallback() {
        state.bufferEnergy = audioProcessor.relativeEnergy
    }

    private func onProgressCallback(_ progress: TranscriptionProgress) {
        let fallbacks = Int(progress.timings.totalDecodingFallbacks)
        if progress.text.count < state.currentText.count {
            if fallbacks == state.currentFallbacks {
                state.unconfirmedText.append(state.currentText)
            } else {
                Logging.info("Fallback occured: \(fallbacks)")
            }
        }
        state.currentText = progress.text
        state.currentFallbacks = fallbacks
    }

    private func transcribeCurrentBuffer() async throws {
        let currentBuffer = audioProcessor.audioSamples
        let nextBufferSize = currentBuffer.count - state.lastBufferSize
        let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)
        let minBufferSeconds = Float(config.minBufferSeconds)

        guard nextBufferSeconds > minBufferSeconds else {
            if state.currentText.isEmpty {
                state.currentText = "Waiting for speech..."
            }
            return try await Task.sleep(nanoseconds: 100_000_000)
        }

        if config.useVAD {
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: config.silenceThreshold
            )
            if !voiceDetected {
                if state.currentText.isEmpty {
                    state.currentText = "Waiting for speech..."
                }
                return try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        state.lastBufferSize = currentBuffer.count

        let transcription = try await transcribeAudioSamples(Array(currentBuffer))

        state.currentText = ""
        state.unconfirmedText = []
        let segments = transcription.segments

        if segments.count > config.requiredSegmentsForConfirmation {
            let numberOfSegmentsToConfirm = segments.count - config.requiredSegmentsForConfirmation
            let confirmedSegmentsArray = Array(segments.prefix(numberOfSegmentsToConfirm))
            let remainingSegments = Array(segments.suffix(config.requiredSegmentsForConfirmation))

            if let lastConfirmed = confirmedSegmentsArray.last,
               lastConfirmed.end > state.lastConfirmedSegmentEndSeconds {
                state.lastConfirmedSegmentEndSeconds = lastConfirmed.end
                state.confirmedSegments.append(contentsOf: confirmedSegmentsArray)
            }

            state.unconfirmedSegments = remainingSegments
        } else {
            state.unconfirmedSegments = segments
        }
    }

    private func transcribeAudioSamples(_ samples: [Float]) async throws -> TranscriptionResult {
        var options = decodingOptions
        options.clipTimestamps = [state.lastConfirmedSegmentEndSeconds]
        let checkWindow = config.compressionCheckWindow
        return try await transcribeTask.run(audioArray: samples, decodeOptions: options) { [weak self] progress in
            Task { [weak self] in
                await self?.onProgressCallback(progress)
            }
            return StreamingTranscriber.shouldStopEarly(
                progress: progress,
                options: options,
                compressionCheckWindow: checkWindow
            )
        }
    }

    private static func shouldStopEarly(
        progress: TranscriptionProgress,
        options: DecodingOptions,
        compressionCheckWindow: Int
    ) -> Bool? {
        let currentTokens = progress.tokens
        if currentTokens.count > compressionCheckWindow {
            let checkTokens: [Int] = currentTokens.suffix(compressionCheckWindow)
            let compressionRatio = TextUtilities.compressionRatio(of: checkTokens)
            if compressionRatio > options.compressionRatioThreshold ?? 0.0 {
                return false
            }
        }
        if let avgLogprob = progress.avgLogprob, let logProbThreshold = options.logProbThreshold {
            if avgLogprob < logProbThreshold {
                return false
            }
        }
        return nil
    }
}
