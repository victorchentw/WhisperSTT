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

                if model.mode == .stt {
                    sttSection
                } else {
                    ttsSection
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
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
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
    }

    enum SttMode: String, CaseIterable {
        case clip = "Clip"
        case streaming = "Streaming"
    }

    @Published var mode: Mode = .stt {
        didSet {
            guard oldValue != mode else { return }
            if isRecording {
                stopRecording()
            }
            if isStreaming {
                Task { await stopStreaming() }
            }
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

    private let recorder = AudioRecorder()
    private let whisper = WhisperEngine()
    private let tts = TTSService()
    private var toastTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
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
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await whisper.transcribe(audioURL: audioURL)
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
}

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
