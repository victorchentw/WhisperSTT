import Foundation
import SwiftUI
import WhisperKit

@MainActor
final class AppViewModel: ObservableObject {
    enum Mode: String, CaseIterable {
        case stt = "STT"
        case tts = "TTS"
        case benchmark = "Benchmark"
    }

    enum SttEngine: String, CaseIterable {
        case whisper = "WhisperKit"
        case nexa = "NexaSDK"
        case runAnywhere = "RunAnywhere"
    }

    enum SttMode: String, CaseIterable {
        case clip = "Clip"
        case streaming = "Streaming"
    }

    static let customNexaModelId = "__custom__"
    static let customRunAnywhereModelId = "__custom__"
    static let benchmarkRecordedSourceId = "__recorded__"
    static let benchmarkManualTranscriptId = "__manual_transcript__"

    @Published var mode: Mode = .stt {
        didSet {
            guard oldValue != mode else { return }
            if isRecording {
                stopRecording()
            }
            if isStreaming {
                Task { await stopStreaming() }
            }
            if benchmarkIsRecording {
                stopBenchmarkRecording()
            }
        }
    }
    @Published var sttEngine: SttEngine = .whisper {
        didSet {
            guard oldValue != sttEngine else { return }
            if isRecording {
                stopRecording()
            }
            if isStreaming {
                Task { await stopStreaming() }
            }
            statusText = "Ready"
        }
    }
    @Published var sttMode: SttMode = .clip {
        didSet {
            guard oldValue != sttMode else { return }
            if isRecording {
                stopRecording()
            }
            if isStreaming {
                Task { await stopStreaming() }
            }
            statusText = "Ready"
        }
    }
    @Published var sttText: String = ""
    @Published var ttsText: String = "Hello, Whisper on iOS."
    @Published var nexaSelectedModelId: String = NexaModelCatalog.models.first?.id ?? AppViewModel.customNexaModelId
    @Published var nexaCustomModelPath: String = ""
    @Published var nexaLanguage: NexaLanguage = .en
    @Published var nexaChunkSeconds: Double = 4.0 {
        didSet {
            let maxOverlap = max(0.0, nexaChunkSeconds - 0.1)
            if nexaOverlapSeconds > maxOverlap {
                nexaOverlapSeconds = maxOverlap
            }
        }
    }
    @Published var nexaOverlapSeconds: Double = 1.0 {
        didSet {
            let maxOverlap = max(0.0, nexaChunkSeconds - 0.1)
            if nexaOverlapSeconds < 0 {
                nexaOverlapSeconds = 0
            } else if nexaOverlapSeconds > maxOverlap {
                nexaOverlapSeconds = maxOverlap
            }
        }
    }
    @Published var runAnywhereSelectedModelId: String = RunAnywhereModelCatalog.models.first?.id ?? AppViewModel.customRunAnywhereModelId
    @Published var runAnywhereCustomModelId: String = ""
    @Published var runAnywhereLanguage: String = "auto"
    @Published var runAnywhereDetectLanguage: Bool = true
    @Published var runAnywhereChunkSeconds: Double = 3.0 {
        didSet {
            let maxOverlap = max(0.0, runAnywhereChunkSeconds - 0.1)
            if runAnywhereOverlapSeconds > maxOverlap {
                runAnywhereOverlapSeconds = maxOverlap
            }
        }
    }
    @Published var runAnywhereOverlapSeconds: Double = 0.8 {
        didSet {
            let maxOverlap = max(0.0, runAnywhereChunkSeconds - 0.1)
            if runAnywhereOverlapSeconds < 0 {
                runAnywhereOverlapSeconds = 0
            } else if runAnywhereOverlapSeconds > maxOverlap {
                runAnywhereOverlapSeconds = maxOverlap
            }
        }
    }
    @Published var metrics: PerformanceMetrics?
    @Published var errorMessage: String?
    @Published var isRecording = false
    @Published var isStreaming = false
    @Published var isProcessing = false
    @Published var isSpeaking = false
    @Published var statusText = "Ready"
    @Published var toast: ToastMessage?

    @Published var streamingMinBufferSeconds: Double = 1.5
    @Published var streamingConfirmSegments: Int = 2
    @Published var streamingUseVAD: Bool = true
    @Published var streamingSilenceThreshold: Double = 0.3

    @Published var benchmarkSelectedClipId: String = AppViewModel.benchmarkRecordedSourceId {
        didSet {
            guard oldValue != benchmarkSelectedClipId else { return }
            applyBenchmarkClipSelection()
        }
    }
    @Published var benchmarkSelectedTranscriptId: String = AppViewModel.benchmarkManualTranscriptId {
        didSet {
            guard oldValue != benchmarkSelectedTranscriptId else { return }
            applyBenchmarkTranscriptSelection()
        }
    }
    @Published var benchmarkReferenceText: String = ""
    @Published var benchmarkAudioURL: URL?
    @Published var benchmarkIsRecording: Bool = false
    @Published var benchmarkIsRunning: Bool = false
    @Published var benchmarkStatus: String = "Ready"
    @Published var benchmarkIncludeWhisper: Bool = true
    @Published var benchmarkIncludeNexa: Bool = true
    @Published var benchmarkIncludeRunAnywhere: Bool = true
    @Published var benchmarkNexaModelIds: Set<String> = Set(NexaModelCatalog.models.map { $0.id })
    @Published var benchmarkRunAnywhereModelIds: Set<String> = Set(RunAnywhereModelCatalog.models.map { $0.id })
    @Published var benchmarkResults: [BenchmarkResult] = []

    private let recorder = AudioRecorder()
    private let whisper = WhisperKitEngine()
    private let nexa = NexaEngine()
    private let runAnywhere = RunAnywhereEngine()
    private let tts = TTSService()
    private var toastTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var activeStreamingEngine: SttEngine?
    private var lastStreamingText: String = ""

    init() {
        if let firstClip = benchmarkBundledClips.first {
            benchmarkSelectedClipId = firstClip.id
            benchmarkSelectedTranscriptId = firstClip.id
            applyBenchmarkClipSelection()
            applyBenchmarkTranscriptSelection()
        }
    }

    var isSttActive: Bool {
        sttMode == .streaming ? isStreaming : isRecording
    }

    var sttButtonTitle: String {
        if sttMode == .streaming {
            return isStreaming ? "Stop" : "Start"
        }
        return isRecording ? "Stop" : "Record"
    }

    var sttButtonIcon: String {
        if sttMode == .streaming {
            return isStreaming ? "stop.circle.fill" : "waveform.circle.fill"
        }
        return isRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    var nexaBundledModels: [BundledModel] {
        NexaModelCatalog.models
    }

    var runAnywhereBundledModels: [BundledModel] {
        RunAnywhereModelCatalog.models
    }

    var benchmarkBundledClips: [BenchmarkClip] {
        BenchmarkClipCatalog.clips
    }

    var benchmarkUsesRecordedAudio: Bool {
        benchmarkSelectedClipId == Self.benchmarkRecordedSourceId
    }

    var selectedBenchmarkClip: BenchmarkClip? {
        benchmarkBundledClips.first { $0.id == benchmarkSelectedClipId }
    }

    var selectedBenchmarkTranscriptClip: BenchmarkClip? {
        benchmarkBundledClips.first { $0.id == benchmarkSelectedTranscriptId }
    }

    var nexaSelectedModelIsReady: Bool {
        let path = resolvedNexaModelPath
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    var nexaSelectedModelStatusText: String {
        if nexaSelectedModelId == Self.customNexaModelId {
            return nexaSelectedModelIsReady ? "Custom model path OK." : "Custom model path not found."
        }
        if selectedNexaModel == nil, let fallback = selectedOrFallbackNexaModel {
            return "Selected model id not found. Falling back to: \(fallback.displayName)."
        }
        return nexaSelectedModelIsReady ? "Bundled model found." : "Bundled model missing in app resources."
    }

    var runAnywhereSelectedModelIsReady: Bool {
        if runAnywhereSelectedModelId == Self.customRunAnywhereModelId {
            return !runAnywhereCustomModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let model = selectedRunAnywhereModel else { return false }
        return RunAnywhereModelCatalog.bundleURL(for: model) != nil
    }

    var runAnywhereSelectedModelStatusText: String {
        if runAnywhereSelectedModelId == Self.customRunAnywhereModelId {
            return runAnywhereSelectedModelIsReady ? "Custom model ID set." : "Custom model ID is empty."
        }
        return runAnywhereSelectedModelIsReady ? "Bundled model found." : "Bundled model missing in app resources."
    }

    private var selectedNexaModel: BundledModel? {
        nexaBundledModels.first { $0.id == nexaSelectedModelId }
    }

    private var selectedOrFallbackNexaModel: BundledModel? {
        if let selectedNexaModel,
           NexaModelCatalog.bundleURL(for: selectedNexaModel) != nil {
            return selectedNexaModel
        }
        return nexaBundledModels.first { NexaModelCatalog.bundleURL(for: $0) != nil }
    }

    private var selectedRunAnywhereModel: BundledModel? {
        runAnywhereBundledModels.first { $0.id == runAnywhereSelectedModelId }
    }

    private var resolvedNexaModelPath: String {
        if nexaSelectedModelId == Self.customNexaModelId {
            return nexaCustomModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let model = selectedOrFallbackNexaModel,
              let url = NexaModelCatalog.bundleURL(for: model) else {
            return ""
        }
        return url.path
    }

    private func resolvedNexaModelPathForExecution() -> String {
        let path = resolvedNexaModelPath
        guard !path.isEmpty else { return "" }

        // If stale model id no longer exists, auto-fallback to the first valid bundled model.
        if nexaSelectedModelId != Self.customNexaModelId,
           selectedNexaModel == nil,
           let fallback = selectedOrFallbackNexaModel,
           nexaSelectedModelId != fallback.id {
            nexaSelectedModelId = fallback.id
            logEvent("Nexa model id invalid, auto-fallback to \(fallback.id)")
        }
        return path
    }

    private var resolvedRunAnywhereModelId: String {
        if runAnywhereSelectedModelId == Self.customRunAnywhereModelId {
            return runAnywhereCustomModelId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return runAnywhereSelectedModelId
    }

    var benchmarkRecordButtonTitle: String {
        benchmarkIsRecording ? "Stop" : "Record"
    }

    var benchmarkRecordButtonIcon: String {
        benchmarkIsRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private func applyBenchmarkClipSelection() {
        if benchmarkSelectedClipId == Self.benchmarkRecordedSourceId {
            if benchmarkAudioURL == nil {
                benchmarkStatus = "Record benchmark audio or choose a bundled clip."
            } else {
                benchmarkStatus = "Benchmark audio ready."
            }
            return
        }

        guard let clip = selectedBenchmarkClip else {
            benchmarkAudioURL = nil
            benchmarkStatus = "Invalid benchmark clip."
            errorMessage = "Selected benchmark clip not found."
            return
        }

        guard let audioURL = BenchmarkClipCatalog.audioURL(for: clip) else {
            benchmarkAudioURL = nil
            benchmarkStatus = "Bundled benchmark clip missing."
            errorMessage = "Bundled benchmark clip missing: \(clip.audioFileName)"
            return
        }

        benchmarkAudioURL = audioURL
        benchmarkStatus = "Bundled clip ready."
        logEvent("Benchmark clip selected: \(clip.audioFileName)")
    }

    private func applyBenchmarkTranscriptSelection() {
        guard benchmarkSelectedTranscriptId != Self.benchmarkManualTranscriptId else {
            return
        }

        guard let clip = selectedBenchmarkTranscriptClip else {
            errorMessage = "Selected transcript clip not found."
            return
        }

        guard let text = BenchmarkClipCatalog.transcriptText(for: clip) else {
            errorMessage = "Bundled transcript missing: \(clip.transcriptFileName)"
            return
        }

        benchmarkReferenceText = text
        logEvent("Benchmark transcript selected: \(clip.transcriptFileName)")
    }

    func toggleRecording() {
        switch sttMode {
        case .clip:
            if isRecording {
                stopRecording()
            } else {
                Task { await startRecording() }
            }
        case .streaming:
            if isStreaming {
                Task { await stopStreaming() }
            } else {
                startStreaming()
            }
        }
    }

    func toggleSpeaking() {
        if isSpeaking {
            tts.stop()
            isSpeaking = false
            statusText = "Stopped"
        } else {
            startSpeaking()
        }
    }

    func toggleBenchmarkRecording() {
        if benchmarkIsRecording {
            stopBenchmarkRecording()
        } else {
            Task { await startBenchmarkRecording() }
        }
    }

    private func startBenchmarkRecording() async {
        if isRecording {
            stopRecording()
        }
        if isStreaming {
            Task { await stopStreaming() }
        }
        benchmarkSelectedClipId = Self.benchmarkRecordedSourceId

        errorMessage = nil
        benchmarkStatus = "Requesting microphone..."
        let granted = await recorder.requestPermission()
        guard granted else {
            errorMessage = "Microphone permission denied. Enable it in Settings."
            benchmarkStatus = "Permission denied"
            logEvent("Microphone permission denied")
            return
        }

        do {
            try recorder.startRecording()
            benchmarkIsRecording = true
            benchmarkAudioURL = nil
            benchmarkStatus = "Recording benchmark..."
            logEvent("Benchmark recording started")
        } catch {
            errorMessage = error.localizedDescription
            benchmarkStatus = "Error"
            logEvent("Benchmark recording error: \(error.localizedDescription)")
        }
    }

    private func stopBenchmarkRecording() {
        guard benchmarkIsRecording else { return }
        let audioURL = recorder.stopRecording()
        benchmarkIsRecording = false
        if let audioURL {
            benchmarkSelectedClipId = Self.benchmarkRecordedSourceId
            benchmarkAudioURL = audioURL
            benchmarkStatus = "Benchmark audio ready."
            logEvent("Benchmark recording saved: \(audioURL.lastPathComponent)")
        } else {
            benchmarkStatus = "No audio captured."
            logEvent("Benchmark recording returned no audio URL")
        }
    }

    func runBenchmark() {
        guard !benchmarkIsRunning else { return }
        guard let audioURL = benchmarkAudioURL else {
            errorMessage = "Select a bundled benchmark clip or record benchmark audio first."
            benchmarkStatus = "Missing audio"
            return
        }

        let reference = benchmarkReferenceText
        let includeWhisper = benchmarkIncludeWhisper
        let includeNexa = benchmarkIncludeNexa
        let includeRunAnywhere = benchmarkIncludeRunAnywhere
        let nexaModelIds = benchmarkNexaModelIds
        let runAnywhereModelIds = benchmarkRunAnywhereModelIds
        let hasNexa = includeNexa && !nexaModelIds.isEmpty
        let hasRunAnywhere = includeRunAnywhere && !runAnywhereModelIds.isEmpty
        if !includeWhisper && !hasNexa && !hasRunAnywhere {
            benchmarkStatus = "No models selected."
            return
        }

        benchmarkIsRunning = true
        benchmarkResults = []
        benchmarkStatus = "Benchmark running..."

        let whisper = self.whisper
        let nexa = self.nexa
        let runAnywhere = self.runAnywhere
        let nexaModels = self.nexaBundledModels
        let runAnywhereModels = self.runAnywhereBundledModels
        // Benchmark should always use language auto-detection for fair multilingual comparison.
        let runAnywhereLanguage = "auto"
        let runAnywhereDetect = true

        if hasRunAnywhere {
            logEvent("Benchmark RunAnywhere language forced to auto-detect")
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var results: [BenchmarkResult] = []

            func addResult(engine: String, model: String, result: WhisperTranscriptionResult, latency: TimeInterval) {
                let refTrimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
                let wer = refTrimmed.isEmpty ? nil : Benchmarking.wordErrorRate(reference: reference, hypothesis: result.text)
                let cer = refTrimmed.isEmpty ? nil : Benchmarking.charErrorRate(reference: reference, hypothesis: result.text)

                results.append(
                    BenchmarkResult(
                        engine: engine,
                        model: model,
                        mode: "Clip",
                        text: result.text,
                        latency: latency,
                        processing: result.processingTime,
                        audioDuration: result.audioDuration,
                        realTimeFactor: result.realTimeFactor,
                        wer: wer,
                        cer: cer,
                        error: nil
                    )
                )
            }

            func addError(engine: String, model: String, error: Error) {
                results.append(
                    BenchmarkResult(
                        engine: engine,
                        model: model,
                        mode: "Clip",
                        text: "",
                        latency: nil,
                        processing: nil,
                        audioDuration: nil,
                        realTimeFactor: nil,
                        wer: nil,
                        cer: nil,
                        error: error.localizedDescription
                    )
                )
            }

            if includeWhisper {
                do {
                    await MainActor.run {
                        self.benchmarkStatus = "Initializing WhisperKit model..."
                    }
                    try await whisper.prepareModel()
                    await MainActor.run {
                        self.benchmarkStatus = "Benchmarking WhisperKit..."
                    }
                    let start = Date()
                    let result = try await whisper.transcribe(audioURL: audioURL)
                    let latency = Date().timeIntervalSince(start)
                    addResult(engine: "WhisperKit", model: "tiny", result: result, latency: latency)
                } catch {
                    addError(engine: "WhisperKit", model: "tiny", error: error)
                }
            }

            if hasNexa {
                for modelId in nexaModelIds {
                    guard let model = nexaModels.first(where: { $0.id == modelId }),
                          let url = NexaModelCatalog.bundleURL(for: model) else {
                        addError(
                            engine: "NexaSDK",
                            model: modelId,
                            error: BenchmarkError.modelMissing(modelId)
                        )
                        continue
                    }
                    do {
                        await MainActor.run {
                            self.benchmarkStatus = "Initializing \(model.displayName)..."
                        }
                        try await nexa.prepareModel(modelPath: url.path)
                        await MainActor.run {
                            self.benchmarkStatus = "Benchmarking \(model.displayName)..."
                        }
                        let start = Date()
                        let result = try await nexa.transcribe(audioURL: audioURL, modelPath: url.path)
                        let latency = Date().timeIntervalSince(start)
                        addResult(engine: "NexaSDK", model: model.displayName, result: result, latency: latency)
                    } catch {
                        addError(engine: "NexaSDK", model: model.displayName, error: error)
                    }
                }
            }

            if hasRunAnywhere {
                for modelId in runAnywhereModelIds {
                    let modelName = runAnywhereModels.first(where: { $0.id == modelId })?.displayName ?? modelId
                    do {
                        await MainActor.run {
                            self.benchmarkStatus = "Initializing \(modelName)..."
                        }
                        try await runAnywhere.prepareModel(modelId: modelId)
                        await MainActor.run {
                            self.benchmarkStatus = "Benchmarking \(modelName)..."
                        }
                        let start = Date()
                        let result = try await runAnywhere.transcribe(
                            audioURL: audioURL,
                            modelId: modelId,
                            language: runAnywhereLanguage,
                            detectLanguage: runAnywhereDetect
                        )
                        let latency = Date().timeIntervalSince(start)
                        addResult(engine: "RunAnywhere", model: modelName, result: result, latency: latency)
                    } catch {
                        addError(engine: "RunAnywhere", model: modelName, error: error)
                    }
                }
            }

            await MainActor.run {
                self.benchmarkResults = results
                self.benchmarkIsRunning = false
                self.benchmarkStatus = "Benchmark completed."
            }
        }
    }

    private func startRecording() async {
        errorMessage = nil
        statusText = "Requesting microphone..."
        logEvent("Requesting microphone permission")
        let granted = await recorder.requestPermission()
        guard granted else {
            errorMessage = "Microphone permission denied. Enable it in Settings."
            statusText = "Permission denied"
            logEvent("Microphone permission denied")
            return
        }

        do {
            try recorder.startRecording()
            isRecording = true
            statusText = "Listening..."
            logEvent("Recording started")
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Error"
            logEvent("Recording error: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        let stopTime = Date()
        let audioURL = recorder.stopRecording()
        isRecording = false
        logEvent("Recording stopped")

        guard let audioURL else {
            errorMessage = "No audio was recorded."
            statusText = "Error"
            logEvent("No audio URL returned")
            return
        }

        isProcessing = true
        statusText = "Initializing model..."
        logEvent("Transcribing audio: \(audioURL.lastPathComponent)")

        if let attributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
           let fileSize = attributes[.size] as? NSNumber {
            logEvent("Audio file size: \(fileSize.intValue) bytes")
        }

        let whisper = self.whisper
        let nexa = self.nexa
        let runAnywhere = self.runAnywhere
        let engine = self.sttEngine
        let nexaPath = self.resolvedNexaModelPathForExecution()
        let runAnywhereModelId = self.resolvedRunAnywhereModelId
        let runAnywhereLanguage = self.runAnywhereLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let runAnywhereDetect = self.runAnywhereDetectLanguage
        Task.detached(priority: .userInitiated) {
            do {
                let initName: String
                switch engine {
                case .whisper:
                    initName = "WhisperKit"
                case .nexa:
                    initName = "NexaSDK"
                case .runAnywhere:
                    initName = "RunAnywhere"
                }
                await MainActor.run {
                    self.statusText = "Initializing \(initName) model..."
                    self.logEvent("\(initName) model initialization started", showToast: false)
                }

                switch engine {
                case .whisper:
                    try await whisper.prepareModel()
                case .nexa:
                    try await nexa.prepareModel(modelPath: nexaPath)
                case .runAnywhere:
                    try await runAnywhere.prepareModel(modelId: runAnywhereModelId)
                }

                await MainActor.run {
                    self.statusText = "Transcribing..."
                    self.logEvent("\(initName) model initialization completed", showToast: false)
                }

                let result: WhisperTranscriptionResult
                switch engine {
                case .whisper:
                    result = try await whisper.transcribe(audioURL: audioURL)
                case .nexa:
                    result = try await nexa.transcribe(audioURL: audioURL, modelPath: nexaPath)
                case .runAnywhere:
                    let language = runAnywhereLanguage.isEmpty ? "auto" : runAnywhereLanguage
                    result = try await runAnywhere.transcribe(
                        audioURL: audioURL,
                        modelId: runAnywhereModelId,
                        language: language,
                        detectLanguage: runAnywhereDetect
                    )
                }
                let latency = Date().timeIntervalSince(stopTime)
                await MainActor.run {
                    self.sttText = result.text
                    self.metrics = PerformanceMetrics.stt(
                        processing: result.processingTime,
                        audioDuration: result.audioDuration,
                        latency: latency,
                        realTimeFactor: result.realTimeFactor
                    )
                    self.statusText = "Done"
                    self.isProcessing = false
                    if result.text.isEmpty {
                        self.logEvent("No speech recognized")
                    } else {
                        self.logEvent("Transcription complete (\(result.text.count) chars)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Error"
                    self.isProcessing = false
                    self.logEvent("Transcription error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startStreaming() {
        let selectedEngine = sttEngine
        let engine = streamingEngine(for: selectedEngine)
        guard let config = streamingConfig(for: selectedEngine) else { return }

        errorMessage = nil
        metrics = nil
        sttText = ""
        lastStreamingText = ""
        isStreaming = true
        activeStreamingEngine = selectedEngine
        statusText = "Initializing \(engine.displayName) model..."
        logEvent("\(engine.displayName) streaming started")

        streamingTask?.cancel()
        streamingTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let granted = await AudioProcessor.requestRecordPermission()
            guard granted else {
                self.errorMessage = "Microphone permission denied. Enable it in Settings."
                self.statusText = "Permission denied"
                self.isStreaming = false
                self.activeStreamingEngine = nil
                self.logEvent("Microphone permission denied")
                return
            }

            do {
                self.statusText = "Initializing \(engine.displayName) model..."
                self.logEvent("\(engine.displayName) model initialization started", showToast: false)
                try await engine.prepareStreaming(config: config)
                self.statusText = "Starting stream..."
                self.logEvent("\(engine.displayName) model initialization completed", showToast: false)
                try await engine.startStreaming(config: config) { update in
                    Task { @MainActor in
                        self.applyStreamingUpdate(update)
                    }
                }
            } catch is CancellationError {
                self.logEvent("\(engine.displayName) streaming cancelled", showToast: false)
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusText = "Error"
                self.isStreaming = false
                self.activeStreamingEngine = nil
                self.logEvent("\(engine.displayName) streaming error: \(error.localizedDescription)")
            }
        }
    }

    private func stopStreaming() async {
        guard isStreaming else { return }
        let engineId = activeStreamingEngine ?? sttEngine
        let engine = streamingEngine(for: engineId)
        statusText = "Stopping..."
        logEvent("\(engine.displayName) streaming stop requested")

        streamingTask?.cancel()
        streamingTask = nil
        await engine.stopStreaming()
        AudioRecorder.deactivateSession()
        isStreaming = false
        activeStreamingEngine = nil
        statusText = "Done"
        logEvent("\(engine.displayName) streaming stopped")
    }

    private func streamingEngine(for engine: SttEngine) -> any STTStreamingEngine {
        switch engine {
        case .whisper:
            return whisper
        case .nexa:
            return nexa
        case .runAnywhere:
            return runAnywhere
        }
    }

    private func streamingConfig(for engine: SttEngine) -> STTStreamingStartConfig? {
        switch engine {
        case .whisper:
            return .whisper(
                StreamingConfig(
                    minBufferSeconds: streamingMinBufferSeconds,
                    requiredSegmentsForConfirmation: streamingConfirmSegments,
                    silenceThreshold: Float(streamingSilenceThreshold),
                    compressionCheckWindow: 60,
                    useVAD: streamingUseVAD
                )
            )
        case .nexa:
            let nexaPath = resolvedNexaModelPathForExecution()
            guard !nexaPath.isEmpty else {
                errorMessage = "Nexa model path is missing."
                statusText = "Error"
                logEvent("Nexa model path missing")
                return nil
            }
            let config = NexaStreamingConfig(
                language: nexaLanguage,
                chunkSeconds: nexaChunkSeconds,
                overlapSeconds: nexaOverlapSeconds
            )
            return .nexa(
                NexaStreamingStartConfig(
                    modelPath: nexaPath,
                    config: config
                )
            )
        case .runAnywhere:
            let modelId = resolvedRunAnywhereModelId
            guard !modelId.isEmpty else {
                errorMessage = "RunAnywhere model ID is missing."
                statusText = "Error"
                logEvent("RunAnywhere model ID missing")
                return nil
            }
            let language = runAnywhereLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            return .runAnywhere(
                RunAnywhereStreamingStartConfig(
                    modelId: modelId,
                    language: language.isEmpty ? "auto" : language,
                    detectLanguage: runAnywhereDetectLanguage,
                    chunkSeconds: runAnywhereChunkSeconds,
                    overlapSeconds: runAnywhereOverlapSeconds
                )
            )
        }
    }

    private func applyStreamingUpdate(_ update: STTStreamingUpdate) {
        switch update {
        case .replaceText(let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            sttText = normalized
            statusText = normalized.isEmpty ? "Listening..." : "Streaming..."
            if normalized != lastStreamingText {
                lastStreamingText = normalized
                logEvent("Streaming update (\(normalized.count) chars)", showToast: false)
            }
        case .appendChunk(let text):
            updateChunkedStreamingText(text)
        }
    }

    private func startSpeaking() {
        errorMessage = nil
        isSpeaking = true
        statusText = "Speaking..."
        logEvent("TTS started")

        tts.speak(ttsText) { [weak self] latency in
            Task { @MainActor in
                self?.metrics = PerformanceMetrics.tts(latency: latency, total: latency)
                self?.logEvent("TTS first audio in \(String(format: "%.2f", latency))s")
            }
        } onFinish: { [weak self] latency, total in
            Task { @MainActor in
                self?.metrics = PerformanceMetrics.tts(latency: latency, total: total)
                self?.isSpeaking = false
                self?.statusText = "Done"
                self?.logEvent("TTS finished in \(String(format: "%.2f", total))s")
            }
        }
    }

    private func updateChunkedStreamingText(_ text: String) {
        let merged = mergeStreamingText(lastStreamingText, text)
        sttText = merged
        lastStreamingText = merged
        statusText = merged.isEmpty ? "Listening..." : "Streaming..."
        logEvent("Chunked streaming update (\(merged.count) chars)", showToast: false)
    }

    private func mergeStreamingText(_ confirmed: String, _ newText: String) -> String {
        let cleanNew = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanNew.isEmpty { return confirmed }
        let cleanConfirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanConfirmed.isEmpty { return cleanNew }

        let confirmedWords = cleanConfirmed.split(separator: " ")
        let newWords = cleanNew.split(separator: " ")
        let maxCheck = min(6, min(confirmedWords.count, newWords.count))
        if maxCheck > 0 {
            for k in stride(from: maxCheck, through: 1, by: -1) {
                let suffix = confirmedWords.suffix(k)
                let prefix = newWords.prefix(k)
                if suffix.elementsEqual(prefix, by: { $0.caseInsensitiveCompare($1) == .orderedSame }) {
                    let merged = confirmedWords.dropLast(k) + newWords
                    return merged.joined(separator: " ")
                }
            }
        }
        return (cleanConfirmed + " " + cleanNew).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logEvent(_ message: String, showToast: Bool = true) {
        print("[WhisperiOS] \(message)")
        guard showToast else { return }
        let toastMessage = ToastMessage(text: message)
        withAnimation(.easeInOut(duration: 0.2)) {
            toast = toastMessage
        }

        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if self?.toast?.id == toastMessage.id {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self?.toast = nil
                    }
                }
            }
        }
    }

    private func showToast(_ message: String) {
        logEvent(message, showToast: true)
    }
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
