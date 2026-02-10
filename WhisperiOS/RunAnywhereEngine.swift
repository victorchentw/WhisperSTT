import AVFoundation
import Foundation
import ONNXRuntime
import RunAnywhere

enum RunAnywhereEngineError: LocalizedError {
    case modelIdMissing
    case audioConversionFailed
    case modelBundleMissing(String)
    case modelCopyFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelIdMissing:
            return "RunAnywhere model ID is required."
        case .audioConversionFailed:
            return "Failed to convert audio for RunAnywhere."
        case .modelBundleMissing(let name):
            return "Bundled RunAnywhere model not found: \(name)."
        case .modelCopyFailed(let message):
            return "Failed to copy RunAnywhere model: \(message)."
        }
    }
}

final class RunAnywhereEngine {
    private var isInitialized = false
    private var loadedModelId: String?
    private let sampleRate: Double = 16_000

    func transcribe(
        audioURL: URL,
        modelId: String,
        language: String,
        detectLanguage: Bool
    ) async throws -> WhisperTranscriptionResult {
        guard !modelId.isEmpty else {
            throw RunAnywhereEngineError.modelIdMissing
        }

        try await ensureInitialized()
        try await loadModelIfNeeded(modelId)

        let (audioData, duration) = try Self.loadAudioData(from: audioURL, sampleRate: sampleRate)
        let options = STTOptions(
            language: language,
            detectLanguage: detectLanguage,
            sampleRate: Int(sampleRate)
        )

        let output = try await RunAnywhere.transcribeWithOptions(audioData, options: options)
        return WhisperTranscriptionResult(
            text: output.text,
            processingTime: output.metadata.processingTime,
            audioDuration: duration,
            realTimeFactor: output.metadata.realTimeFactor
        )
    }

    func startChunkedStreaming(
        modelId: String,
        language: String,
        detectLanguage: Bool,
        chunkSeconds: Double,
        overlapSeconds: Double,
        onText: @escaping (String) -> Void
    ) async throws -> RunAnywhereStreamingSession {
        guard !modelId.isEmpty else {
            throw RunAnywhereEngineError.modelIdMissing
        }

        try await ensureInitialized()
        try await loadModelIfNeeded(modelId)

        let options = STTOptions(
            language: language,
            detectLanguage: detectLanguage,
            sampleRate: Int(sampleRate)
        )

        let session = RunAnywhereStreamingSession(
            options: options,
            sampleRate: sampleRate,
            chunkSeconds: chunkSeconds,
            overlapSeconds: overlapSeconds,
            onText: onText
        )
        try session.start()
        return session
    }

    private func ensureInitialized() async throws {
        if !RunAnywhere.isSDKInitialized {
            try RunAnywhere.initialize()
        }
        await MainActor.run {
            ONNX.register()
        }
        guard !isInitialized else { return }
        try await registerBundledModels()
        isInitialized = true
    }

    private func loadModelIfNeeded(_ modelId: String) async throws {
        if loadedModelId != modelId {
            try await RunAnywhere.loadSTTModel(modelId)
            loadedModelId = modelId
        }
    }

    private func registerBundledModels() async throws {
        for model in RunAnywhereModelCatalog.models {
            guard let bundleURL = RunAnywhereModelCatalog.bundleURL(for: model) else {
                continue
            }

            let modelFolder = try CppBridge.ModelPaths.getModelFolder(
                modelId: model.id,
                framework: .onnx
            )

            if !FileManager.default.fileExists(atPath: modelFolder.path) || isDirectoryEmpty(modelFolder) {
                do {
                    try copyBundledModel(from: bundleURL, to: modelFolder)
                } catch {
                    throw RunAnywhereEngineError.modelCopyFailed(error.localizedDescription)
                }
            }

            let modelInfo = ModelInfo(
                id: model.id,
                name: model.displayName,
                category: .speechRecognition,
                format: .onnx,
                framework: .onnx,
                downloadURL: nil,
                localPath: modelFolder,
                artifactType: .singleFile(expectedFiles: .none),
                downloadSize: nil,
                contextLength: nil,
                supportsThinking: false,
                description: "Bundled model",
                source: .local
            )

            try await CppBridge.ModelRegistry.shared.save(modelInfo)
        }
    }

    private func copyBundledModel(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return contents.isEmpty
    }

    private static func loadAudioData(from url: URL, sampleRate: Double) throws -> (Data, TimeInterval) {
        let audioFile = try AVAudioFile(forReading: url)
        let inputFormat = audioFile.processingFormat
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )

        guard let outputFormat else {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        let frameCapacity = AVAudioFrameCount(audioFile.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        try audioFile.read(into: inputBuffer)

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if error != nil || outputBuffer.frameLength == 0 {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData else {
            throw RunAnywhereEngineError.audioConversionFailed
        }

        let count = Int(outputBuffer.frameLength)
        let data = Data(bytes: channelData[0], count: count * MemoryLayout<Float>.size)
        let duration = Double(count) / sampleRate
        return (data, duration)
    }
}

final class RunAnywhereStreamingSession {
    private let recorder: AudioStreamRecorder
    private let buffer: AudioSampleBuffer
    private let options: STTOptions
    private let chunkSeconds: Double
    private let overlapSeconds: Double
    private let onText: (String) -> Void
    private var task: Task<Void, Never>?

    init(
        options: STTOptions,
        sampleRate: Double,
        chunkSeconds: Double,
        overlapSeconds: Double,
        onText: @escaping (String) -> Void
    ) {
        self.options = options
        self.chunkSeconds = max(0.5, chunkSeconds)
        self.overlapSeconds = max(0.0, min(overlapSeconds, chunkSeconds - 0.1))
        self.onText = onText
        self.recorder = AudioStreamRecorder(sampleRate: sampleRate)
        self.buffer = AudioSampleBuffer(sampleRate: sampleRate, maxSeconds: 30)
    }

    func start() throws {
        try AudioRecorder.configureSessionForVoiceProcessing()
        try recorder.start { [weak self] samples in
            self?.buffer.append(samples)
        }

        let interval = max(0.5, chunkSeconds - overlapSeconds)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let snapshot = self.buffer.snapshotLast(seconds: self.chunkSeconds + self.overlapSeconds)
                guard !snapshot.isEmpty else { continue }
                let data = snapshot.withUnsafeBytes { Data($0) }
                do {
                    let output = try await RunAnywhere.transcribeStream(audioData: data, options: self.options) { partial in
                        Task { @MainActor in
                            self.onText(partial.transcript)
                        }
                    }
                    Task { @MainActor in
                        self.onText(output.text)
                    }
                } catch {
                    continue
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
}

private final class AudioSampleBuffer {
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
        let count = min(samples.count, Int(sampleRate * seconds))
        guard count > 0 else { return [] }
        lock.lock()
        let result = Array(samples.suffix(count))
        lock.unlock()
        return result
    }
}

private final class AudioStreamRecorder {
    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let queue = DispatchQueue(label: "runanywhere.audio.stream")
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
