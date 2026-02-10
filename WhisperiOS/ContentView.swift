import Foundation
import SwiftUI
import WhisperKit

struct ContentView: View {
    @StateObject private var model = AppViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppViewModel.Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                switch model.mode {
                case .stt:
                    Picker("Engine", selection: $model.sttEngine) {
                        ForEach(AppViewModel.SttEngine.allCases, id: \.self) { engine in
                            Text(engine.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.sttEngine == .nexa {
                        nexaConfigSection
                    } else if model.sttEngine == .runAnywhere {
                        runAnywhereConfigSection
                    }

                    sttSection
                case .tts:
                    ttsSection
                case .benchmark:
                    benchmarkSection
                }

                metricsSection

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 8)
            }
            .padding()
            .navigationTitle("Razer Whisper")
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    ToastView(text: toast.text)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                        .zIndex(1)
                }
            }
        }
    }

    private var sttSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("STT Mode", selection: $model.sttMode) {
                ForEach(AppViewModel.SttMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Button {
                    model.toggleRecording()
                } label: {
                    Label(model.sttButtonTitle, systemImage: model.sttButtonIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isSttActive ? .red : .blue)
                .disabled(model.isProcessing && model.sttMode == .clip)

                if model.isProcessing {
                    ProgressView()
                } else {
                    Text(model.statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Text("Transcription")
                .font(.headline)

            TranscriptionScrollView(text: model.sttText)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            if model.sttMode == .streaming {
                DisclosureGroup("Streaming Settings") {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.sttEngine == .whisper {
                            HStack {
                                Text("Min buffer (s)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.2f", model.streamingMinBufferSeconds))
                                    .font(.footnote)
                            }
                            Slider(value: $model.streamingMinBufferSeconds, in: 0.5...4.0, step: 0.1)

                            HStack {
                                Text("Confirm segments")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(model.streamingConfirmSegments)")
                                    .font(.footnote)
                            }
                            Stepper("", value: $model.streamingConfirmSegments, in: 1...4)

                            Toggle("Use VAD", isOn: $model.streamingUseVAD)
                                .font(.footnote)

                            if model.streamingUseVAD {
                                HStack {
                                    Text("Silence threshold")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.2f", model.streamingSilenceThreshold))
                                        .font(.footnote)
                                }
                                Slider(value: $model.streamingSilenceThreshold, in: 0.05...0.8, step: 0.05)
                            }
                        } else if model.sttEngine == .nexa {
                            HStack {
                                Text("Language")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Picker("Language", selection: $model.nexaLanguage) {
                                    ForEach(NexaLanguage.allCases, id: \.self) { lang in
                                        Text(lang.rawValue)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 180)
                            }

                            HStack {
                                Text("Chunk (s)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", model.nexaChunkSeconds))
                                    .font(.footnote)
                            }
                            Slider(value: $model.nexaChunkSeconds, in: 1.0...8.0, step: 0.5)

                            let maxOverlap = max(0.0, model.nexaChunkSeconds - 0.1)
                            HStack {
                                Text("Overlap (s)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                            Text(String(format: "%.1f", model.nexaOverlapSeconds))
                                    .font(.footnote)
                            }
                            Slider(value: $model.nexaOverlapSeconds, in: 0.0...maxOverlap, step: 0.1)
                        } else {
                            HStack {
                                Text("Chunk (s)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", model.runAnywhereChunkSeconds))
                                    .font(.footnote)
                            }
                            Slider(value: $model.runAnywhereChunkSeconds, in: 1.0...8.0, step: 0.5)

                            let maxOverlap = max(0.0, model.runAnywhereChunkSeconds - 0.1)
                            HStack {
                                Text("Overlap (s)")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f", model.runAnywhereOverlapSeconds))
                                    .font(.footnote)
                            }
                            Slider(value: $model.runAnywhereOverlapSeconds, in: 0.0...maxOverlap, step: 0.1)

                            Text("RunAnywhere streaming uses chunked decoding with overlap.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
            }
        }
    }

    private var nexaConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nexa model")
                .font(.footnote)
                .foregroundColor(.secondary)

            Picker("Nexa model", selection: $model.nexaSelectedModelId) {
                ForEach(model.nexaBundledModels) { item in
                    Text(item.displayName).tag(item.id)
                }
                Text("Custom Path").tag(AppViewModel.customNexaModelId)
            }
            .pickerStyle(.menu)

            if model.nexaSelectedModelId == AppViewModel.customNexaModelId {
                TextField("e.g. /path/to/nexa/model", text: $model.nexaCustomModelPath)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(model.nexaSelectedModelStatusText)
                    .font(.caption)
                    .foregroundColor(model.nexaSelectedModelIsReady ? .secondary : .red)
            }
        }
    }

    private var runAnywhereConfigSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RunAnywhere model")
                .font(.footnote)
                .foregroundColor(.secondary)

            Picker("RunAnywhere model", selection: $model.runAnywhereSelectedModelId) {
                ForEach(model.runAnywhereBundledModels) { item in
                    Text(item.displayName).tag(item.id)
                }
                Text("Custom Model ID").tag(AppViewModel.customRunAnywhereModelId)
            }
            .pickerStyle(.menu)

            if model.runAnywhereSelectedModelId == AppViewModel.customRunAnywhereModelId {
                TextField("Model ID (must exist in RunAnywhere storage)", text: $model.runAnywhereCustomModelId)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(model.runAnywhereSelectedModelStatusText)
                    .font(.caption)
                    .foregroundColor(model.runAnywhereSelectedModelIsReady ? .secondary : .red)
            }

            HStack {
                Text("Language")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextField("en / zh / auto", text: $model.runAnywhereLanguage)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Detect language", isOn: $model.runAnywhereDetectLanguage)
                .font(.footnote)
        }
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Benchmark")
                .font(.headline)
            Text("Benchmark uses clip audio for consistent WER/CER.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Include WhisperKit", isOn: $model.benchmarkIncludeWhisper)
                .font(.footnote)

            Toggle("Include Nexa", isOn: $model.benchmarkIncludeNexa)
                .font(.footnote)

            if model.benchmarkIncludeNexa {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nexa models")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(model.nexaBundledModels) { item in
                        Toggle(item.displayName, isOn: bindingForSet($model.benchmarkNexaModelIds, id: item.id))
                            .font(.footnote)
                    }
                }
            }

            Toggle("Include RunAnywhere", isOn: $model.benchmarkIncludeRunAnywhere)
                .font(.footnote)

            if model.benchmarkIncludeRunAnywhere {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RunAnywhere models")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    ForEach(model.runAnywhereBundledModels) { item in
                        Toggle(item.displayName, isOn: bindingForSet($model.benchmarkRunAnywhereModelIds, id: item.id))
                            .font(.footnote)
                    }
                }
            }

            Text("Reference text (for WER/CER)")
                .font(.footnote)
                .foregroundColor(.secondary)

            TextEditor(text: $model.benchmarkReferenceText)
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            HStack(spacing: 12) {
                Button {
                    model.toggleBenchmarkRecording()
                } label: {
                    Label(model.benchmarkRecordButtonTitle, systemImage: model.benchmarkRecordButtonIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.benchmarkIsRecording ? .red : .blue)

                Button {
                    model.runBenchmark()
                } label: {
                    Label("Run Benchmark", systemImage: "timer")
                }
                .buttonStyle(.bordered)
                .disabled(model.benchmarkIsRunning || model.benchmarkAudioURL == nil)
            }

            if let url = model.benchmarkAudioURL {
                Text("Benchmark audio: \(url.lastPathComponent)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.benchmarkIsRunning {
                ProgressView(model.benchmarkStatus)
            } else {
                Text(model.benchmarkStatus)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if model.benchmarkResults.isEmpty {
                Text("No benchmark results yet.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(model.benchmarkResults) { result in
                    BenchmarkResultRow(result: result)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text to speak")
                .font(.headline)

            TextEditor(text: $model.ttsText)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))

            HStack(spacing: 12) {
                Button {
                    model.toggleSpeaking()
                } label: {
                    Label(model.isSpeaking ? "Stop" : "Speak", systemImage: model.isSpeaking ? "stop.circle.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isSpeaking ? .red : .green)
                .disabled(model.ttsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Text(model.statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var metricsSection: some View {
        MetricsView(metrics: model.metrics)
    }

    private func bindingForSet(_ set: Binding<Set<String>>, id: String) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { isOn in
                if isOn {
                    set.wrappedValue.insert(id)
                } else {
                    set.wrappedValue.remove(id)
                }
            }
        )
    }
}

private struct MetricsView: View {
    let metrics: PerformanceMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance")
                .font(.headline)

            if let metrics {
                metricRow(title: "Operation", value: metrics.operation.rawValue)
                metricRow(title: "Latency", value: formatMs(metrics.latencySeconds))

                if let processing = metrics.processingSeconds {
                    metricRow(title: "Processing", value: formatMs(processing))
                }

                if let duration = metrics.audioDurationSeconds {
                    metricRow(title: "Audio Duration", value: formatMs(duration))
                }

                if let rtf = metrics.realTimeFactor {
                    metricRow(title: "Real-time Factor", value: String(format: "%.2f", rtf))
                }
            } else {
                Text("No performance data yet.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }

    private func formatMs(_ value: TimeInterval?) -> String {
        guard let value else { return "-" }
        let ms = value * 1000
        if ms < 1000 {
            return String(format: "%.0f ms", ms)
        }
        return String(format: "%.2f s", value)
    }
}

private struct BenchmarkResultRow: View {
    let result: BenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(result.engine) • \(result.model)")
                .font(.subheadline)

            if let error = result.error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            } else {
                HStack {
                    Text("Latency: \(formatSeconds(result.latency))")
                    Spacer()
                    Text("RTF: \(formatMetric(result.realTimeFactor))")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                HStack {
                    Text("WER: \(formatMetric(result.wer))")
                    Spacer()
                    Text("CER: \(formatMetric(result.cer))")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Text(result.text.isEmpty ? "(no text)" : result.text)
                    .font(.footnote)
                    .foregroundColor(.primary)
            }
        }
    }

    private func formatSeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "-" }
        if value < 1 {
            return String(format: "%.0f ms", value * 1000)
        }
        return String(format: "%.2f s", value)
    }

    private func formatMetric(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }
}

private struct TranscriptionScrollView: View {
    let text: String
    private let bottomId = "transcription-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .font(.body)
                    .id(bottomId)
            }
            .background(Color(.systemBackground))
            .scrollIndicators(.visible)
            .onChange(of: text) { _ in
                proxy.scrollTo(bottomId, anchor: .bottom)
            }
        }
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(radius: 6)
    }
}

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
    @Published var runAnywhereLanguage: String = "en"
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
    private let whisper = WhisperEngine()
    private let nexa = NexaEngine()
    private let runAnywhere = RunAnywhereEngine()
    private let tts = TTSService()
    private var toastTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var nexaStreamingTask: Task<Void, Never>?
    private var runAnywhereStreamingSession: RunAnywhereStreamingSession?
    private var lastStreamingText: String = ""

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
            errorMessage = "Record benchmark audio first."
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
        let runAnywhereLanguage = self.runAnywhereLanguage
        let runAnywhereDetect = self.runAnywhereDetectLanguage

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
        statusText = "Transcribing..."
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
                let result: WhisperTranscriptionResult
                switch engine {
                case .whisper:
                    result = try await whisper.transcribe(audioURL: audioURL)
                case .nexa:
                    result = try await nexa.transcribe(audioURL: audioURL, modelPath: nexaPath)
                case .runAnywhere:
                    let language = runAnywhereLanguage.isEmpty ? "en" : runAnywhereLanguage
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
        switch sttEngine {
        case .whisper:
            startWhisperStreaming()
        case .nexa:
            startNexaStreaming()
        case .runAnywhere:
            startRunAnywhereStreaming()
        }
    }

    private func startWhisperStreaming() {
        errorMessage = nil
        metrics = nil
        sttText = ""
        lastStreamingText = ""
        isStreaming = true
        statusText = "Streaming..."
        logEvent("Streaming started")

        let config = StreamingConfig(
            minBufferSeconds: streamingMinBufferSeconds,
            requiredSegmentsForConfirmation: streamingConfirmSegments,
            silenceThreshold: Float(streamingSilenceThreshold),
            compressionCheckWindow: 60,
            useVAD: streamingUseVAD
        )

        streamingTask?.cancel()
        streamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let granted = await AudioProcessor.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                    self.statusText = "Permission denied"
                    self.isStreaming = false
                    self.logEvent("Microphone permission denied")
                }
                return
            }
            do {
                try AudioRecorder.configureSessionForVoiceProcessing()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Audio session error"
                    self.isStreaming = false
                    self.logEvent("Audio session error: \(error.localizedDescription)")
                }
                return
            }
            do {
                try await self.whisper.startStreaming(config: config) { state in
                    Task { @MainActor in
                        self.updateStreamingState(state)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Error"
                    self.isStreaming = false
                    self.logEvent("Streaming error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopStreaming() async {
        guard isStreaming else { return }
        switch sttEngine {
        case .whisper:
            await stopWhisperStreaming()
        case .nexa:
            await stopNexaStreaming()
        case .runAnywhere:
            await stopRunAnywhereStreaming()
        }
    }

    private func stopWhisperStreaming() async {
        statusText = "Stopping..."
        logEvent("Streaming stop requested")
        await whisper.stopStreaming()
        AudioRecorder.deactivateSession()
        isStreaming = false
        streamingTask?.cancel()
        streamingTask = nil
        statusText = "Done"
        logEvent("Streaming stopped")
    }

    private func startNexaStreaming() {
        errorMessage = nil
        metrics = nil
        sttText = ""
        lastStreamingText = ""
        isStreaming = true
        statusText = "Streaming..."
        logEvent("Nexa streaming started")

        let config = NexaStreamingConfig(
            language: nexaLanguage,
            chunkSeconds: nexaChunkSeconds,
            overlapSeconds: nexaOverlapSeconds
        )
        let nexa = self.nexa
        let nexaPath = self.resolvedNexaModelPathForExecution()

        guard !nexaPath.isEmpty else {
            errorMessage = "Nexa model path is missing."
            statusText = "Error"
            isStreaming = false
            logEvent("Nexa model path missing")
            return
        }

        nexaStreamingTask?.cancel()
        nexaStreamingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let granted = await AudioProcessor.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                    self.statusText = "Permission denied"
                    self.isStreaming = false
                    self.logEvent("Microphone permission denied")
                }
                return
            }
            do {
                try AudioRecorder.configureSessionForVoiceProcessing()
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Audio session error"
                    self.isStreaming = false
                    self.logEvent("Audio session error: \(error.localizedDescription)")
                }
                return
            }
            do {
                try await nexa.startStreaming(modelPath: nexaPath, config: config) { text in
                    Task { @MainActor in
                        self.updateChunkedStreamingText(text)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Error"
                    self.isStreaming = false
                    self.logEvent("Nexa streaming error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopNexaStreaming() async {
        statusText = "Stopping..."
        logEvent("Nexa streaming stop requested")
        nexa.stopStreaming()
        AudioRecorder.deactivateSession()
        isStreaming = false
        nexaStreamingTask?.cancel()
        nexaStreamingTask = nil
        statusText = "Done"
        logEvent("Nexa streaming stopped")
    }

    private func startRunAnywhereStreaming() {
        errorMessage = nil
        metrics = nil
        sttText = ""
        lastStreamingText = ""
        isStreaming = true
        statusText = "Streaming..."
        logEvent("RunAnywhere streaming started")
        runAnywhereStreamingSession?.stop()
        runAnywhereStreamingSession = nil

        let modelId = resolvedRunAnywhereModelId
        let language = runAnywhereLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let detect = runAnywhereDetectLanguage
        let chunkSeconds = runAnywhereChunkSeconds
        let overlapSeconds = runAnywhereOverlapSeconds

        guard !modelId.isEmpty else {
            errorMessage = "RunAnywhere model ID is missing."
            statusText = "Error"
            isStreaming = false
            logEvent("RunAnywhere model ID missing")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let granted = await AudioProcessor.requestRecordPermission()
            guard granted else {
                await MainActor.run {
                    self.errorMessage = "Microphone permission denied. Enable it in Settings."
                    self.statusText = "Permission denied"
                    self.isStreaming = false
                    self.logEvent("Microphone permission denied")
                }
                return
            }
            do {
                let session = try await self.runAnywhere.startChunkedStreaming(
                    modelId: modelId,
                    language: language.isEmpty ? "en" : language,
                    detectLanguage: detect,
                    chunkSeconds: chunkSeconds,
                    overlapSeconds: overlapSeconds
                ) { text in
                    Task { @MainActor in
                        self.updateChunkedStreamingText(text)
                    }
                }
                await MainActor.run {
                    self.runAnywhereStreamingSession = session
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.statusText = "Error"
                    self.isStreaming = false
                    self.logEvent("RunAnywhere streaming error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopRunAnywhereStreaming() async {
        statusText = "Stopping..."
        logEvent("RunAnywhere streaming stop requested")
        runAnywhereStreamingSession?.stop()
        runAnywhereStreamingSession = nil
        isStreaming = false
        statusText = "Done"
        logEvent("RunAnywhere streaming stopped")
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

    private func updateStreamingState(_ state: StreamingState) {
        let confirmed = state.confirmedSegments.map { $0.text }.joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments.map { $0.text }.joined(separator: " ")
        var current = state.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == "Waiting for speech..." {
            current = ""
        }
        let combined = [confirmed, unconfirmed, current]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        sttText = combined

        if state.isRecording {
            statusText = current.isEmpty ? "Listening..." : "Streaming..."
        }

        if combined != lastStreamingText {
            lastStreamingText = combined
            logEvent("Streaming update (\(combined.count) chars)", showToast: false)
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
