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

                if model.mode == .benchmark {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            benchmarkSection
                            metricsSection

                            if let errorMessage = model.errorMessage {
                                Text(errorMessage)
                                    .foregroundColor(.red)
                                    .font(.footnote)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                } else {
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
                        EmptyView()
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
            }
            .padding()
            .navigationTitle("STT Solution Tester")
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
                TextField("auto / en / zh / ja", text: $model.runAnywhereLanguage)
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

            Text("Benchmark clip")
                .font(.footnote)
                .foregroundColor(.secondary)

            Picker("Benchmark clip", selection: $model.benchmarkSelectedClipId) {
                Text("Recorded audio").tag(AppViewModel.benchmarkRecordedSourceId)
                ForEach(model.benchmarkBundledClips) { clip in
                    Text(clip.displayName).tag(clip.id)
                }
            }
            .pickerStyle(.menu)

            if let clip = model.selectedBenchmarkClip {
                Text("Clip file: \(clip.audioFileName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Transcript source")
                .font(.footnote)
                .foregroundColor(.secondary)

            Picker("Transcript source", selection: $model.benchmarkSelectedTranscriptId) {
                Text("Manual text").tag(AppViewModel.benchmarkManualTranscriptId)
                ForEach(model.benchmarkBundledClips) { clip in
                    Text("\(clip.displayName) TXT").tag(clip.id)
                }
            }
            .pickerStyle(.menu)

            if model.benchmarkSelectedTranscriptId != AppViewModel.benchmarkManualTranscriptId,
               let clip = model.selectedBenchmarkTranscriptClip {
                Text("Transcript file: \(clip.transcriptFileName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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
                if model.benchmarkUsesRecordedAudio {
                    Button {
                        model.toggleBenchmarkRecording()
                    } label: {
                        Label(model.benchmarkRecordButtonTitle, systemImage: model.benchmarkRecordButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.benchmarkIsRecording ? .red : .blue)
                }

                Button {
                    model.runBenchmark()
                } label: {
                    Label("Run Benchmark", systemImage: "timer")
                }
                .buttonStyle(.bordered)
                .disabled(model.benchmarkIsRunning || model.benchmarkAudioURL == nil)
            }

            if let url = model.benchmarkAudioURL {
                Text(model.benchmarkUsesRecordedAudio ? "Recorded audio: \(url.lastPathComponent)" : "Benchmark audio: \(url.lastPathComponent)")
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

