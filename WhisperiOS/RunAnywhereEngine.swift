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
    // RunAnywhere ONNX backend currently processes only < 30s per request.
    private let maxClipSecondsPerRequest: Double = 29.0
    // Bump this when bundled RunAnywhere model layout/selection logic changes.
    private let bundledModelSyncVersion = "runanywhere-ios-v4"

    func prepareModel(modelId: String) async throws {
        guard !modelId.isEmpty else {
            throw RunAnywhereEngineError.modelIdMissing
        }
        try await ensureInitialized()
        try await loadModelIfNeeded(modelId)
    }

    func transcribe(
        audioURL: URL,
        modelId: String,
        language: String,
        detectLanguage: Bool
    ) async throws -> WhisperTranscriptionResult {
        try await prepareModel(modelId: modelId)

        let (audioData, duration) = try Self.loadAudioData(from: audioURL, sampleRate: sampleRate)
        let normalizedLanguage = Self.normalizedLanguageCode(
            language,
            detectLanguage: detectLanguage
        )
        let options = STTOptions(
            language: normalizedLanguage,
            detectLanguage: detectLanguage,
            sampleRate: Int(sampleRate)
        )

        let samplesPerRequest = max(1, Int(sampleRate * maxClipSecondsPerRequest))
        let bytesPerSample = MemoryLayout<Int16>.size
        let totalSamples = audioData.count / bytesPerSample

        if totalSamples > samplesPerRequest {
            return try await transcribeChunked(
                audioData: audioData,
                duration: duration,
                options: options,
                samplesPerRequest: samplesPerRequest
            )
        }


        let output = try await RunAnywhere.transcribeWithOptions(audioData, options: options)
        return WhisperTranscriptionResult(
            text: output.text,
            processingTime: output.metadata.processingTime,
            audioDuration: duration,
            realTimeFactor: output.metadata.realTimeFactor
        )
    }

    private func transcribeChunked(
        audioData: Data,
        duration: TimeInterval,
        options: STTOptions,
        samplesPerRequest: Int
    ) async throws -> WhisperTranscriptionResult {
        let bytesPerSample = MemoryLayout<Int16>.size
        let totalSamples = audioData.count / bytesPerSample
        let chunkCount = Int(ceil(Double(totalSamples) / Double(samplesPerRequest)))
        print(
            "[RunAnywhereEngine] Long clip (\(String(format: "%.2f", duration))s) split into \(chunkCount) chunks of <= \(String(format: "%.1f", maxClipSecondsPerRequest))s"
        )

        var allTexts: [String] = []
        allTexts.reserveCapacity(chunkCount)
        var totalProcessingTime: TimeInterval = 0

        var startSample = 0
        var chunkIndex = 1
        while startSample < totalSamples {
            let endSample = min(totalSamples, startSample + samplesPerRequest)
            let byteRange = (startSample * bytesPerSample)..<(endSample * bytesPerSample)
            let chunkData = audioData.subdata(in: byteRange)

            let output = try await RunAnywhere.transcribeWithOptions(chunkData, options: options)
            totalProcessingTime += output.metadata.processingTime

            let cleanedText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanedText.isEmpty {
                allTexts.append(cleanedText)
            }

            print(
                "[RunAnywhereEngine] Chunk \(chunkIndex)/\(chunkCount): samples=\(endSample - startSample), text=\(cleanedText.count) chars"
            )

            startSample = endSample
            chunkIndex += 1
        }

        let mergedText = allTexts
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let realTimeFactor = duration > 0 ? (totalProcessingTime / duration) : nil

        return WhisperTranscriptionResult(
            text: mergedText,
            processingTime: totalProcessingTime,
            audioDuration: duration,
            realTimeFactor: realTimeFactor
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
        try await prepareModel(modelId: modelId)

        let normalizedLanguage = Self.normalizedLanguageCode(
            language,
            detectLanguage: detectLanguage
        )
        let options = STTOptions(
            language: normalizedLanguage,
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

            if shouldSyncBundledModel(at: modelFolder) {
                do {
                    try copyBundledModel(from: bundleURL, to: modelFolder)
                    try writeBundleSyncMarker(at: modelFolder)
                } catch {
                    throw RunAnywhereEngineError.modelCopyFailed(error.localizedDescription)
                }
            }

            // Normalize file names so the backend deterministically loads full-precision files.
            try normalizeWhisperOnnxLayoutIfNeeded(in: modelFolder)

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

    private func shouldSyncBundledModel(at modelFolder: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFolder.path) else { return true }
        if isDirectoryEmpty(modelFolder) { return true }

        let markerURL = modelFolder.appendingPathComponent(".bundle-sync-version")
        let marker = (try? String(contentsOf: markerURL, encoding: .utf8))?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return marker != bundledModelSyncVersion
    }

    private func writeBundleSyncMarker(at modelFolder: URL) throws {
        let markerURL = modelFolder.appendingPathComponent(".bundle-sync-version")
        try bundledModelSyncVersion.write(to: markerURL, atomically: true, encoding: .utf8)
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

    private func normalizeWhisperOnnxLayoutIfNeeded(in modelFolder: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFolder.path) else { return }

        let entries = try fm.contentsOfDirectory(
            at: modelFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard !entries.isEmpty else { return }

        let encoderCandidates = entries
            .filter { $0.pathExtension.lowercased() == "onnx" }
            .filter { $0.lastPathComponent.lowercased().contains("encoder") }
        let decoderCandidates = entries
            .filter { $0.pathExtension.lowercased() == "onnx" }
            .filter { $0.lastPathComponent.lowercased().contains("decoder") }
        let tokenCandidates = entries
            .filter { $0.pathExtension.lowercased() == "txt" }
            .filter { $0.lastPathComponent.lowercased().contains("tokens") }

        let chosenEncoder = choosePreferredFile(
            from: encoderCandidates,
            exactName: "encoder.onnx"
        )
        let chosenDecoder = choosePreferredFile(
            from: decoderCandidates,
            exactName: "decoder.onnx"
        )
        let chosenTokens = choosePreferredFile(
            from: tokenCandidates,
            exactName: "tokens.txt"
        )

        try moveToCanonicalNameIfNeeded(
            chosenEncoder,
            canonicalName: "encoder.onnx",
            in: modelFolder
        )
        try moveToCanonicalNameIfNeeded(
            chosenDecoder,
            canonicalName: "decoder.onnx",
            in: modelFolder
        )
        try moveToCanonicalNameIfNeeded(
            chosenTokens,
            canonicalName: "tokens.txt",
            in: modelFolder
        )

        // Keep only canonical whisper files so backend directory scans cannot pick stale/int8 variants.
        try removeNonCanonicalWhisperFiles(in: modelFolder)
    }

    private func choosePreferredFile(from candidates: [URL], exactName: String) -> URL? {
        guard !candidates.isEmpty else { return nil }

        struct CandidateScore {
            let url: URL
            let isLikelyInt8: Bool
            let fileSize: Int64
            let isExactName: Bool
        }

        let scored = candidates.map { url in
            CandidateScore(
                url: url,
                isLikelyInt8: isLikelyInt8File(url.lastPathComponent),
                fileSize: fileSize(for: url),
                isExactName: url.lastPathComponent.lowercased() == exactName.lowercased()
            )
        }

        let sorted = scored.sorted { lhs, rhs in
            // 1) Prefer file names that are not obviously quantized.
            if lhs.isLikelyInt8 != rhs.isLikelyInt8 {
                return !lhs.isLikelyInt8 && rhs.isLikelyInt8
            }
            // 2) Prefer larger file size to avoid stale "renamed int8" canonical files.
            if lhs.fileSize != rhs.fileSize {
                return lhs.fileSize > rhs.fileSize
            }
            // 3) Prefer canonical exact name when precision/size are equivalent.
            if lhs.isExactName != rhs.isExactName {
                return lhs.isExactName && !rhs.isExactName
            }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        return sorted.first?.url
    }

    private func isLikelyInt8File(_ fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        return lowered.contains(".int8.") || lowered.contains("int8") || lowered.contains("quant")
    }

    private func fileSize(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func moveToCanonicalNameIfNeeded(
        _ selected: URL?,
        canonicalName: String,
        in modelFolder: URL
    ) throws {
        guard let selected else { return }
        let canonicalURL = modelFolder.appendingPathComponent(canonicalName)
        if selected.standardizedFileURL == canonicalURL.standardizedFileURL {
            return
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: canonicalURL.path) {
            try fm.removeItem(at: canonicalURL)
        }
        try fm.moveItem(at: selected, to: canonicalURL)
    }

    private func removeNonCanonicalWhisperFiles(in modelFolder: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: modelFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for entry in entries {
            let name = entry.lastPathComponent.lowercased()
            if name == "encoder.onnx" || name == "decoder.onnx" || name == "tokens.txt" {
                continue
            }

            if name == "test_wavs" {
                try? fm.removeItem(at: entry)
                continue
            }

            let shouldRemoveEncoderVariant = name.contains("encoder") && name.hasSuffix(".onnx")
            let shouldRemoveDecoderVariant = name.contains("decoder") && name.hasSuffix(".onnx")
            let shouldRemoveTokenVariant = name.contains("tokens") && name.hasSuffix(".txt")

            if shouldRemoveEncoderVariant || shouldRemoveDecoderVariant || shouldRemoveTokenVariant {
                try? fm.removeItem(at: entry)
            }
        }
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
        let data = pcmInt16Data(from: channelData[0], count: count)
        let duration = Double(count) / sampleRate
        return (data, duration)
    }

    private static func normalizedLanguageCode(_ raw: String, detectLanguage: Bool) -> String {
        // When detection is enabled, force SDK auto-language mode.
        if detectLanguage {
            return ""
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("auto") == .orderedSame {
            return ""
        }
        return trimmed
    }

    private static func pcmInt16Data(from floatPointer: UnsafePointer<Float>, count: Int) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let sample = max(-1.0, min(1.0, floatPointer[index]))
            let scaled = (sample * 32767.0).rounded()
            samples.append(Int16(scaled))
        }
        return samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    fileprivate static func pcmInt16Data(from floatSamples: [Float]) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(floatSamples.count)
        for sample in floatSamples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = (clamped * 32767.0).rounded()
            samples.append(Int16(scaled))
        }
        return samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
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
            var useNativeStreaming = await CppBridge.STT.shared.supportsStreaming
            if !useNativeStreaming {
                print("[RunAnywhereStreamingSession] Native streaming is not supported for current model/backend; fallback to chunked transcribeWithOptions.")
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let snapshot = self.buffer.snapshotLast(seconds: self.chunkSeconds + self.overlapSeconds)
                guard !snapshot.isEmpty else { continue }
                let data = RunAnywhereEngine.pcmInt16Data(from: snapshot)

                if useNativeStreaming {
                    do {
                        let output = try await RunAnywhere.transcribeStream(
                            audioData: data,
                            options: self.options
                        ) { partial in
                            Task { @MainActor in
                                self.onText(partial.transcript)
                            }
                        }
                        Task { @MainActor in
                            self.onText(output.text)
                        }
                        continue
                    } catch {
                        // Some backends report streaming support but fail at runtime.
                        // Keep session alive by falling back to chunked full decode.
                        print("[RunAnywhereStreamingSession] Native streaming failed (\(error.localizedDescription)); fallback to chunked transcribeWithOptions.")
                        useNativeStreaming = false
                    }
                }

                do {
                    let output = try await RunAnywhere.transcribeWithOptions(data, options: self.options)
                    Task { @MainActor in
                        self.onText(output.text)
                    }
                } catch {
                    print("[RunAnywhereStreamingSession] Chunked fallback decode failed: \(error.localizedDescription)")
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
