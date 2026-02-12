import AVFoundation
#if canImport(NexaSdk)
import NexaSdk
#endif

enum NexaEngineError: LocalizedError {
    case sdkMissing
    case modelPathMissing
    case loadFailed(String)
    case transcriptionFailed(String)
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .sdkMissing:
            return "NexaSdk is unavailable for this build target. Use a physical iOS device build with NexaSdk linked."
        case .modelPathMissing:
            return "Nexa model path is required."
        case .loadFailed(let message):
            return "Nexa model load failed: \(message)"
        case .transcriptionFailed(let message):
            return "Nexa transcription failed: \(message)"
        case .streamingFailed(let message):
            return "Nexa streaming failed: \(message)"
        }
    }
}

enum NexaLanguage: String, CaseIterable {
    case en = "en"
    case ch = "ch"
}

struct NexaStreamingConfig {
    var language: NexaLanguage
    var chunkSeconds: Double
    var overlapSeconds: Double
}

final class NexaEngine {
    #if canImport(NexaSdk)
    private var asr: Asr?
    private var fallbackSession: NexaChunkedStreamingSession?
    #else
    private var asr: Any?
    #endif
    private var modelPath: String?
    private let sampleRate = 16_000

    func prepareModel(modelPath: String) async throws {
        let trimmedPath = modelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NexaEngineError.modelPathMissing
        }
        #if canImport(NexaSdk)
        _ = try await loadAsr(modelPath: trimmedPath)
        #else
        throw NexaEngineError.sdkMissing
        #endif
    }

    func transcribe(audioURL: URL, modelPath: String) async throws -> WhisperTranscriptionResult {
        try await prepareModel(modelPath: modelPath)
        #if canImport(NexaSdk)
        guard let asrInstance = asr else {
            throw NexaEngineError.loadFailed("Nexa model is not initialized.")
        }
        let start = Date()
        do {
            let response = try await asrInstance.transcribe(options: .init(audioPath: audioURL.path))
            let duration = try Self.audioDuration(for: audioURL)
            let processing = Date().timeIntervalSince(start)
            return WhisperTranscriptionResult(
                text: response.asrResult.transcript,
                processingTime: processing,
                audioDuration: duration,
                realTimeFactor: nil
            )
        } catch {
            throw NexaEngineError.transcriptionFailed(error.localizedDescription)
        }
        #else
        throw NexaEngineError.sdkMissing
        #endif
    }

    func startStreaming(
        modelPath: String,
        config: NexaStreamingConfig,
        onText: @escaping (String) -> Void
    ) async throws {
        #if canImport(NexaSdk)
        try await prepareModel(modelPath: modelPath)
        guard let asrInstance = asr else {
            throw NexaEngineError.loadFailed("Nexa model is not initialized.")
        }
        print(
            "[NexaEngine] startStreaming language=\(config.language.rawValue) chunk=\(String(format: "%.2f", config.chunkSeconds)) overlap=\(String(format: "%.2f", config.overlapSeconds))"
        )
        var streamConfig = ASRStreamConfig()
        streamConfig.language = toSdkLanguage(config.language)
        streamConfig.chunkDuration = Float(max(1.0, config.chunkSeconds))
        streamConfig.overlapDuration = Float(max(0.0, min(config.overlapSeconds, config.chunkSeconds - 0.1)))
        streamConfig.sampleRate = Int32(sampleRate)

        // Ensure stale stream state is cleared before creating a new stream/session.
        asrInstance.stopRecordingStream()
        fallbackSession?.stop()
        fallbackSession = nil

        actor EmissionState {
            private(set) var didEmit = false
            func mark() { didEmit = true }
        }

        let emissionState = EmissionState()

        let nativeStreamingTask = Task {
            let stream = try asrInstance.startRecordingStream(config: streamConfig)
            for try await text in stream {
                if Task.isCancelled { break }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                await emissionState.mark()
                print("[NexaEngine] native streaming chunk (\(cleaned.count) chars)")
                onText(cleaned)
            }
        }

        // Native Nexa stream may initialize but never emit. If no text arrives quickly,
        // switch to a chunked fallback so UI keeps updating.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if Task.isCancelled {
            nativeStreamingTask.cancel()
            asrInstance.stopRecordingStream()
            fallbackSession?.stop()
            fallbackSession = nil
            throw CancellationError()
        }

        let didEmitNativeText = await emissionState.didEmit
        if didEmitNativeText {
            do {
                try await nativeStreamingTask.value
                print("[NexaEngine] native streaming ended")
                return
            } catch is CancellationError {
                print("[NexaEngine] native streaming cancelled")
                throw CancellationError()
            } catch {
                throw NexaEngineError.streamingFailed(error.localizedDescription)
            }
        }

        print("[NexaEngine] native stream produced no text within 5s, fallback to chunked transcription")
        nativeStreamingTask.cancel()
        asrInstance.stopRecordingStream()
        _ = try? await nativeStreamingTask.value

        let fallback = NexaChunkedStreamingSession(
            asr: asrInstance,
            sampleRate: Double(sampleRate),
            chunkSeconds: config.chunkSeconds,
            overlapSeconds: config.overlapSeconds,
            onText: onText
        )

        do {
            fallbackSession = fallback
            try fallback.start()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            fallback.stop()
            fallbackSession = nil
            throw CancellationError()
        } catch is CancellationError {
            fallback.stop()
            fallbackSession = nil
            throw CancellationError()
        } catch {
            fallback.stop()
            fallbackSession = nil
            throw NexaEngineError.streamingFailed(error.localizedDescription)
        }
        #else
        throw NexaEngineError.sdkMissing
        #endif
    }

    func stopStreaming() async {
        #if canImport(NexaSdk)
        asr?.stopRecordingStream()
        fallbackSession?.stop()
        fallbackSession = nil
        #endif
    }

    private static func audioDuration(for url: URL) throws -> TimeInterval {
        let audioFile = try AVAudioFile(forReading: url)
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(Double(audioFile.length) / sampleRate)
    }

    #if canImport(NexaSdk)
    private func loadAsr(modelPath: String) async throws -> Asr {
        if let asr, self.modelPath == modelPath {
            return asr
        }
        let url = URL(fileURLWithPath: modelPath)
        do {
            let asrInstance = try Asr(plugin: .ane)
            try await asrInstance.load(from: url)
            asr = asrInstance
            self.modelPath = modelPath
            return asrInstance
        } catch {
            throw NexaEngineError.loadFailed(error.localizedDescription)
        }
    }

    private func toSdkLanguage(_ lang: NexaLanguage) -> Language {
        switch lang {
        case .en: return .en
        case .ch: return .ch
        }
    }
    #endif
}

extension NexaEngine: STTStreamingEngine {
    var displayName: String {
        "NexaSDK"
    }

    func prepareStreaming(config: STTStreamingStartConfig) async throws {
        guard case .nexa(let request) = config else {
            throw STTStreamingConfigError.invalidConfig(engine: displayName)
        }
        try await prepareModel(modelPath: request.modelPath)
    }

    func startStreaming(
        config: STTStreamingStartConfig,
        onUpdate: @escaping (STTStreamingUpdate) -> Void
    ) async throws {
        guard case .nexa(let request) = config else {
            throw STTStreamingConfigError.invalidConfig(engine: displayName)
        }

        try await startStreaming(modelPath: request.modelPath, config: request.config) { text in
            onUpdate(.appendChunk(text))
        }
    }
}

#if canImport(NexaSdk)
private final class NexaChunkedStreamingSession {
    private let asr: Asr
    private let sampleRate: Double
    private let chunkSeconds: Double
    private let overlapSeconds: Double
    private let onText: (String) -> Void
    private let recorder: NexaAudioStreamRecorder
    private let buffer: NexaAudioSampleBuffer
    private var task: Task<Void, Never>?

    init(
        asr: Asr,
        sampleRate: Double,
        chunkSeconds: Double,
        overlapSeconds: Double,
        onText: @escaping (String) -> Void
    ) {
        self.asr = asr
        self.sampleRate = sampleRate
        self.chunkSeconds = max(1.0, chunkSeconds)
        self.overlapSeconds = max(0.0, min(overlapSeconds, chunkSeconds - 0.1))
        self.onText = onText
        self.recorder = NexaAudioStreamRecorder(sampleRate: sampleRate)
        self.buffer = NexaAudioSampleBuffer(sampleRate: sampleRate, maxSeconds: 30)
    }

    func start() throws {
        try AudioRecorder.configureSessionForVoiceProcessing()
        try recorder.start { [weak self] samples in
            self?.buffer.append(samples)
        }

        let interval = max(0.6, chunkSeconds - overlapSeconds)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let snapshot = self.buffer.snapshotLast(seconds: self.chunkSeconds + self.overlapSeconds)
                guard !snapshot.isEmpty else { continue }
                do {
                    let wavURL = try Self.writeTempWav(samples: snapshot, sampleRate: Int(self.sampleRate))
                    defer { try? FileManager.default.removeItem(at: wavURL) }
                    let response = try await self.asr.transcribe(options: .init(audioPath: wavURL.path))
                    let cleaned = response.asrResult.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { continue }
                    print("[NexaEngine] fallback chunk (\(cleaned.count) chars)")
                    Task { @MainActor in
                        self.onText(cleaned)
                    }
                } catch {
                    print("[NexaEngine] fallback chunk error: \(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        recorder.stop()
        AudioRecorder.deactivateSession()
    }

    private static func writeTempWav(samples: [Float], sampleRate: Int) throws -> URL {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            pcm.append(Int16((clamped * 32767.0).rounded()))
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let dataByteCount = pcm.count * MemoryLayout<Int16>.size

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(36 + dataByteCount), to: &wav)
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16), to: &wav)      // fmt chunk size
        appendLE(UInt16(1), to: &wav)       // PCM format
        appendLE(channels, to: &wav)
        appendLE(UInt32(sampleRate), to: &wav)
        appendLE(byteRate, to: &wav)
        appendLE(blockAlign, to: &wav)
        appendLE(bitsPerSample, to: &wav)
        wav.append("data".data(using: .ascii)!)
        appendLE(UInt32(dataByteCount), to: &wav)
        pcm.withUnsafeBufferPointer { ptr in
            wav.append(Data(buffer: ptr))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nexa_stream_\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wav.write(to: url, options: .atomic)
        return url
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}

private final class NexaAudioSampleBuffer {
    private var samples: [Float] = []
    private let sampleRate: Double
    private let maxSamples: Int
    private let lock = NSLock()

    init(sampleRate: Double, maxSeconds: Double) {
        self.sampleRate = sampleRate
        self.maxSamples = Int(sampleRate * maxSeconds)
    }

    func append(_ newSamples: [Float]) {
        guard !newSamples.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: newSamples)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        lock.unlock()
    }

    func snapshotLast(seconds: Double) -> [Float] {
        lock.lock()
        let count = min(samples.count, Int(sampleRate * seconds))
        guard count > 0 else {
            lock.unlock()
            return []
        }
        let result = Array(samples.suffix(count))
        lock.unlock()
        return result
    }
}

private final class NexaAudioStreamRecorder {
    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "nexa.audio.stream")
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat
    private var isRunning = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func start(onSamples: @escaping ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            self.queue.async {
                let ratio = self.outputFormat.sampleRate / inputFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: outCapacity) else {
                    return
                }

                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
                if error != nil || outputBuffer.frameLength == 0 {
                    return
                }

                guard let channelData = outputBuffer.floatChannelData else {
                    return
                }

                let count = Int(outputBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
                onSamples(samples)
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
#endif
