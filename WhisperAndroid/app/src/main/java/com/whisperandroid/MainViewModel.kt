package com.whisperandroid

import android.app.Application
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.min

private data class EngineTranscription(
    val text: String,
    val latencyMs: Long,
    val audioSec: Double,
    val usedNativeStreaming: Boolean = false,
    val usedChunkFallback: Boolean = false
)

private data class ChunkConfig(
    val chunkSeconds: Float,
    val overlapSeconds: Float
)

private data class LanguageHint(
    val language: String,
    val detectLanguage: Boolean
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val tag = "WhisperAndroid"
    private val appContext = application.applicationContext

    private val sherpaEngine = WhisperSttEngine(appContext)
    private val nexaEngine = NexaSttEngine(appContext)
    private val runAnywhereEngine = RunAnywhereSttEngine(appContext)

    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT
    private val languageOptions = listOf("auto", "en", "zh", "ja", "ko", "fr", "de", "es")

    private val _uiState = MutableStateFlow(AppUiState())
    val uiState: StateFlow<AppUiState> = _uiState.asStateFlow()

    val toastFlow = MutableSharedFlow<String>(extraBufferCapacity = 32)

    private var audioRecord: AudioRecord? = null
    private var recordJob: Job? = null
    private var decodeJob: Job? = null

    private val clipChunks = mutableListOf<FloatArray>()
    private val streamFullChunks = mutableListOf<FloatArray>()

    private val streamWindowLock = Any()
    private val streamWindowChunks = ArrayDeque<FloatArray>()
    private var streamWindowSamples = 0

    private var noiseSuppressor: NoiseSuppressor? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var agc: AutomaticGainControl? = null

    private var totalLatencyMs = 0L
    private var totalRtf = 0.0
    private var statsCount = 0

    private var modelReadyKey: String? = null
    private var runAnywhereFallbackNoticeShown = false

    private var tts: TextToSpeech? = null

    fun getLanguageOptions(): List<String> = languageOptions

    fun setMode(mode: AppMode) {
        updateUi { it.copy(mode = mode) }
    }

    fun setSttMode(mode: SttMode) {
        updateUi { it.copy(sttMode = mode) }
    }

    fun setSttEngine(engine: SttEngineType) {
        updateUi {
            it.copy(
                sttEngine = engine,
                status = "Switched to ${engine.displayName}"
            )
        }
        invalidateModelInit("Model not initialized")
    }

    fun setLanguage(language: String) {
        updateUi {
            it.copy(
                language = language,
                detectLanguage = if (language == "auto") true else it.detectLanguage
            )
        }
        invalidateModelInit("Language changed")
    }

    fun setDetectLanguage(enabled: Boolean) {
        updateUi { it.copy(detectLanguage = enabled) }
    }

    fun setSherpaModel(modelId: String) {
        updateUi { it.copy(sherpaModelId = modelId) }
        invalidateModelInit("Sherpa-ONNX model changed")
    }

    fun setNexaModel(modelId: String) {
        updateUi { it.copy(nexaModelId = modelId) }
        invalidateModelInit("Nexa model changed")
    }

    fun setRunAnywhereModel(modelId: String) {
        updateUi { it.copy(runAnywhereModelId = modelId) }
        invalidateModelInit("RunAnywhere model changed")
    }

    fun setNexaChunkSeconds(value: Float) {
        val sanitized = value.coerceIn(1.0f, 12.0f)
        updateUi {
            it.copy(
                nexaChunkSeconds = sanitized,
                nexaOverlapSeconds = it.nexaOverlapSeconds.coerceIn(0.0f, (sanitized - 0.1f).coerceAtLeast(0.0f))
            )
        }
    }

    fun setNexaOverlapSeconds(value: Float) {
        val currentChunk = _uiState.value.nexaChunkSeconds
        val sanitized = value.coerceIn(0.0f, (currentChunk - 0.1f).coerceAtLeast(0.0f))
        updateUi { it.copy(nexaOverlapSeconds = sanitized) }
    }

    fun setRunAnywhereChunkSeconds(value: Float) {
        val sanitized = value.coerceIn(1.0f, 12.0f)
        updateUi {
            it.copy(
                runAnywhereChunkSeconds = sanitized,
                runAnywhereOverlapSeconds = it.runAnywhereOverlapSeconds.coerceIn(0.0f, (sanitized - 0.1f).coerceAtLeast(0.0f))
            )
        }
    }

    fun setRunAnywhereOverlapSeconds(value: Float) {
        val currentChunk = _uiState.value.runAnywhereChunkSeconds
        val sanitized = value.coerceIn(0.0f, (currentChunk - 0.1f).coerceAtLeast(0.0f))
        updateUi { it.copy(runAnywhereOverlapSeconds = sanitized) }
    }

    fun initializeSelectedModel() {
        viewModelScope.launch(Dispatchers.Default) {
            ensureSelectedModelInitialized(force = true)
        }
    }

    fun startClip() {
        if (_uiState.value.isListening) return
        viewModelScope.launch(Dispatchers.Default) {
            if (!ensureSelectedModelInitialized()) return@launch

            clipChunks.clear()
            updateUi {
                it.copy(
                    isListening = true,
                    status = "Listening (clip)",
                    transcription = ""
                )
            }
            log("Start clip recording", toast = true)

            startRecording { chunk ->
                if (chunk.isNotEmpty()) {
                    synchronized(clipChunks) {
                        clipChunks.add(chunk)
                    }
                }
            }
        }
    }

    fun stopClipAndTranscribe() {
        if (!_uiState.value.isListening) return
        stopRecording()

        updateUi {
            it.copy(
                isListening = false,
                isProcessing = true,
                status = "Transcribing (clip)"
            )
        }

        val samples = synchronized(clipChunks) {
            flattenFloatChunks(clipChunks.toList()).also { clipChunks.clear() }
        }

        if (samples.isEmpty()) {
            updateUi {
                it.copy(
                    isProcessing = false,
                    status = "Idle"
                )
            }
            log("No audio captured", toast = true)
            return
        }

        decodeJob?.cancel()
        decodeJob = viewModelScope.launch(Dispatchers.Default) {
            val result = runCatching {
                transcribeWithSelectedEngine(samples, isStreamingChunk = false)
            }
            result.onSuccess { output ->
                applyTranscriptionResult(output, replaceText = true)
                updateUi {
                    it.copy(
                        isProcessing = false,
                        status = "Idle"
                    )
                }
            }.onFailure { error ->
                updateUi {
                    it.copy(
                        isProcessing = false,
                        status = "Error: ${error.message ?: "unknown"}"
                    )
                }
                log("Clip transcription failed: ${error.message}", toast = true)
            }
        }
    }

    fun startStreaming() {
        if (_uiState.value.isListening) return

        viewModelScope.launch(Dispatchers.Default) {
            if (!ensureSelectedModelInitialized()) return@launch

            synchronized(streamWindowLock) {
                streamWindowChunks.clear()
                streamWindowSamples = 0
            }
            streamFullChunks.clear()
            runAnywhereFallbackNoticeShown = false

            updateUi {
                it.copy(
                    isListening = true,
                    status = "Listening (streaming)",
                    transcription = ""
                )
            }
            log("Start streaming", toast = true)
            if (_uiState.value.sttEngine == SttEngineType.NEXA) {
                log("Nexa streaming uses chunked fallback mode")
            }

            startRecording { chunk ->
                if (chunk.isEmpty()) return@startRecording
                streamFullChunks.add(chunk)
                appendStreamWindow(chunk)

                val stateSnapshot = _uiState.value
                val cfg = chunkConfig(stateSnapshot)
                val chunkSamples = (cfg.chunkSeconds * sampleRate).toInt().coerceAtLeast(sampleRate)
                if (currentWindowSamples() < chunkSamples) return@startRecording
                if (decodeJob?.isActive == true) return@startRecording

                val snapshot = snapshotStreamWindow()
                if (snapshot.isEmpty()) return@startRecording
                trimStreamWindow((cfg.overlapSeconds * sampleRate).toInt())

                decodeJob = viewModelScope.launch(Dispatchers.Default) {
                    val partial = runCatching {
                        transcribeWithSelectedEngine(snapshot, isStreamingChunk = true)
                    }
                    partial.onSuccess { output ->
                        applyTranscriptionResult(output, replaceText = false)
                        val merged = mergeStreamingText(_uiState.value.transcription, output.text)
                        updateUi {
                            it.copy(
                                transcription = merged,
                                status = "Listening (streaming)"
                            )
                        }
                        if (output.usedChunkFallback && !runAnywhereFallbackNoticeShown) {
                            runAnywhereFallbackNoticeShown = true
                            log("Native streaming unavailable, switched to chunk fallback", toast = true)
                        }
                    }.onFailure { error ->
                        log("Streaming chunk failed: ${error.message}")
                    }
                }
            }
        }
    }

    fun stopStreaming() {
        if (!_uiState.value.isListening) return
        stopRecording()

        updateUi {
            it.copy(
                isListening = false,
                isProcessing = true,
                status = "Transcribing final result"
            )
        }

        val finalSamples = flattenFloatChunks(streamFullChunks)
        streamFullChunks.clear()

        if (finalSamples.isEmpty()) {
            updateUi {
                it.copy(
                    isProcessing = false,
                    status = "Idle"
                )
            }
            return
        }

        decodeJob?.cancel()
        decodeJob = viewModelScope.launch(Dispatchers.Default) {
            val result = runCatching {
                transcribeWithSelectedEngine(finalSamples, isStreamingChunk = false)
            }
            result.onSuccess { output ->
                applyTranscriptionResult(output, replaceText = true)
                updateUi {
                    it.copy(
                        isProcessing = false,
                        status = "Idle"
                    )
                }
            }.onFailure { error ->
                updateUi {
                    it.copy(
                        isProcessing = false,
                        status = "Error: ${error.message ?: "unknown"}"
                    )
                }
                log("Final transcription failed: ${error.message}", toast = true)
            }
        }
    }

    fun updateTtsText(text: String) {
        updateUi { it.copy(ttsText = text) }
    }

    fun startSpeaking() {
        val text = _uiState.value.ttsText.trim()
        if (text.isEmpty()) {
            log("TTS text is empty", toast = true)
            return
        }
        ensureTts()
        if (!_uiState.value.ttsReady) {
            log("TTS is not ready", toast = true)
            return
        }
        updateUi { it.copy(status = "Speaking") }
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "whisperandroid_tts")
    }

    fun stopSpeaking() {
        tts?.stop()
        updateUi {
            it.copy(
                isSpeaking = false,
                status = "Idle"
            )
        }
    }

    fun setBenchmarkClip(clipId: String) {
        updateUi {
            it.copy(
                benchmarkClipId = clipId,
                benchmarkTranscriptId = clipId,
                benchmarkStatus = "Ready"
            )
        }
    }

    fun toggleBenchmarkIncludeSherpa() {
        updateUi { it.copy(benchmarkIncludeSherpa = !it.benchmarkIncludeSherpa) }
    }

    fun toggleBenchmarkIncludeNexa() {
        updateUi { it.copy(benchmarkIncludeNexa = !it.benchmarkIncludeNexa) }
    }

    fun toggleBenchmarkIncludeRunAnywhere() {
        updateUi { it.copy(benchmarkIncludeRunAnywhere = !it.benchmarkIncludeRunAnywhere) }
    }

    fun toggleBenchmarkNexaModel(modelId: String) {
        updateUi {
            val next = it.benchmarkNexaModelIds.toMutableSet()
            if (!next.add(modelId)) {
                next.remove(modelId)
            }
            it.copy(benchmarkNexaModelIds = next)
        }
    }

    fun toggleBenchmarkRunAnywhereModel(modelId: String) {
        updateUi {
            val next = it.benchmarkRunAnywhereModelIds.toMutableSet()
            if (!next.add(modelId)) {
                next.remove(modelId)
            }
            it.copy(benchmarkRunAnywhereModelIds = next)
        }
    }

    fun runBenchmark() {
        val state = _uiState.value
        if (state.benchmarkRunning) return

        viewModelScope.launch(Dispatchers.Default) {
            val clip = BenchmarkClipCatalog.clips.find { it.id == _uiState.value.benchmarkClipId }
            if (clip == null) {
                updateUi { it.copy(benchmarkStatus = "Clip not found") }
                return@launch
            }

            updateUi {
                it.copy(
                    benchmarkRunning = true,
                    benchmarkStatus = "Loading benchmark clip...",
                    benchmarkResults = emptyList()
                )
            }

            val prepared = runCatching {
                val (samples, sr) = AudioUtils.readWavFromAssets(appContext, clip.audioAssetPath)
                val reference = appContext.assets.open(clip.transcriptAssetPath).bufferedReader().use { it.readText() }.trim()
                Triple(samples, sr, reference)
            }

            if (prepared.isFailure) {
                val message = prepared.exceptionOrNull()?.message ?: "Unknown error"
                updateUi {
                    it.copy(
                        benchmarkRunning = false,
                        benchmarkStatus = "Missing benchmark assets. Ensure benchmark clips exist under app/src/main/assets/benchmark-clips. Details: $message"
                    )
                }
                return@launch
            }

            val (samples, sr, referenceText) = prepared.getOrThrow()
            updateUi {
                it.copy(
                    benchmarkReferenceText = referenceText,
                    benchmarkStatus = "Benchmark running..."
                )
            }

            val baseState = _uiState.value
            val languageHint = languageHintForClip(clip)
            val results = mutableListOf<BenchmarkResult>()

            fun publish(result: BenchmarkResult) {
                results.add(result)
                updateUi {
                    it.copy(
                        benchmarkResults = results.toList()
                    )
                }
            }

            suspend fun runOne(
                engine: String,
                modelName: String,
                block: suspend () -> EngineTranscription
            ) {
                val output = runCatching { block() }
                output.onSuccess { out ->
                    val wer = Benchmarking.wordErrorRate(referenceText, out.text)
                    val cer = Benchmarking.charErrorRate(referenceText, out.text)
                    publish(
                        BenchmarkResult(
                            engine = engine,
                            model = modelName,
                            text = out.text,
                            latencyMs = out.latencyMs,
                            audioDurationSec = out.audioSec,
                            realTimeFactor = if (out.audioSec > 0.0) out.latencyMs / 1000.0 / out.audioSec else null,
                            wer = wer,
                            cer = cer
                        )
                    )
                }.onFailure { error ->
                    publish(
                        BenchmarkResult(
                            engine = engine,
                            model = modelName,
                            error = error.message ?: "Unknown error"
                        )
                    )
                }
            }

            if (baseState.benchmarkIncludeSherpa) {
                val model = SherpaOnnxModelCatalog.models.find { it.id == baseState.sherpaModelId }
                    ?: SherpaOnnxModelCatalog.models.first()
                updateUi { it.copy(benchmarkStatus = "Benchmarking ${model.displayName}...") }
                runOne("Sherpa-ONNX", model.displayName) {
                    sherpaEngine.prepare(model.assetFolderOrFile, languageHint.language)
                    val start = SystemClock.elapsedRealtime()
                    val text = sherpaEngine.transcribe(samples, sr, languageHint.language, model.assetFolderOrFile)
                    val latencyMs = SystemClock.elapsedRealtime() - start
                    EngineTranscription(
                        text = text.trim(),
                        latencyMs = latencyMs,
                        audioSec = samples.size.toDouble() / sr.toDouble()
                    )
                }
            }

            if (baseState.benchmarkIncludeNexa) {
                val selectedModels = NexaModelCatalog.models.filter { baseState.benchmarkNexaModelIds.contains(it.id) }
                for (model in selectedModels) {
                    updateUi { it.copy(benchmarkStatus = "Benchmarking ${model.displayName}...") }
                    runOne("Nexa SDK", model.displayName) {
                        nexaEngine.prepareModel(model, languageHint.language)
                        val out = nexaEngine.transcribe(samples, sr, model, languageHint.language)
                        EngineTranscription(
                            text = out.text,
                            latencyMs = (out.processingSeconds * 1000.0).toLong(),
                            audioSec = out.audioSeconds
                        )
                    }
                }
            }

            if (baseState.benchmarkIncludeRunAnywhere) {
                val selectedModels = RunAnywhereModelCatalog.models.filter {
                    baseState.benchmarkRunAnywhereModelIds.contains(it.id)
                }
                for (model in selectedModels) {
                    updateUi { it.copy(benchmarkStatus = "Benchmarking ${model.displayName}...") }
                    runOne("RunAnywhere", model.displayName) {
                        val out = transcribeRunAnywhereClipWithChunkFallback(
                            samples = samples,
                            sampleRate = sr,
                            model = model,
                            language = languageHint.language,
                            detectLanguage = languageHint.detectLanguage
                        )
                        EngineTranscription(
                            text = out.text,
                            latencyMs = (out.processingSeconds * 1000.0).toLong(),
                            audioSec = out.audioSeconds
                        )
                    }
                }
            }

            updateUi {
                it.copy(
                    benchmarkRunning = false,
                    benchmarkStatus = "Benchmark completed (${results.size} result(s))"
                )
            }
        }
    }

    private suspend fun ensureSelectedModelInitialized(force: Boolean = false): Boolean {
        val state = _uiState.value
        val model = selectedModel(state)
        val key = selectedModelKey(state)

        if (!force && modelReadyKey == key && state.modelInitState == ModelInitState.READY) {
            return true
        }

        updateUi {
            it.copy(
                modelInitState = ModelInitState.INITIALIZING,
                modelInitMessage = "Initializing ${model.displayName}...",
                status = "Initializing ${state.sttEngine.displayName}"
            )
        }

        val result = runCatching {
            when (state.sttEngine) {
                SttEngineType.WHISPER -> {
                    sherpaEngine.prepare(model.assetFolderOrFile, state.language)
                }
                SttEngineType.NEXA -> {
                    nexaEngine.prepareModel(model, state.language)
                }
                SttEngineType.RUN_ANYWHERE -> {
                    runAnywhereEngine.prepareModel(model)
                }
            }
        }

        return result.fold(
            onSuccess = {
                modelReadyKey = key
                updateUi {
                    it.copy(
                        modelInitState = ModelInitState.READY,
                        modelInitMessage = "Ready: ${model.displayName}",
                        status = "Idle"
                    )
                }
                log("Model initialized: ${model.displayName}")
                true
            },
            onFailure = { error ->
                modelReadyKey = null
                updateUi {
                    it.copy(
                        modelInitState = ModelInitState.FAILED,
                        modelInitMessage = "Initialization failed: ${error.message ?: "unknown"}",
                        status = "Model init failed"
                    )
                }
                log("Model initialization failed: ${error.message}", toast = true)
                false
            }
        )
    }

    private suspend fun transcribeWithSelectedEngine(
        samples: FloatArray,
        isStreamingChunk: Boolean
    ): EngineTranscription {
        val state = _uiState.value
        val model = selectedModel(state)

        return when (state.sttEngine) {
            SttEngineType.WHISPER -> {
                val start = SystemClock.elapsedRealtime()
                val text = sherpaEngine.transcribe(
                    samples = samples,
                    sampleRate = sampleRate,
                    language = state.language,
                    modelAssetPath = model.assetFolderOrFile
                )
                val latencyMs = SystemClock.elapsedRealtime() - start
                EngineTranscription(
                    text = text.trim(),
                    latencyMs = latencyMs,
                    audioSec = samples.size.toDouble() / sampleRate.toDouble()
                )
            }

            SttEngineType.NEXA -> {
                val output = nexaEngine.transcribe(
                    samples = samples,
                    sampleRate = sampleRate,
                    model = model,
                    language = state.language
                )
                EngineTranscription(
                    text = output.text,
                    latencyMs = (output.processingSeconds * 1000.0).toLong(),
                    audioSec = output.audioSeconds
                )
            }

            SttEngineType.RUN_ANYWHERE -> {
                if (isStreamingChunk) {
                    val output = runAnywhereEngine.transcribeStreamingChunk(
                        samples = samples,
                        sampleRate = sampleRate,
                        model = model,
                        language = state.language,
                        detectLanguage = state.detectLanguage,
                        preferNativeStreaming = true
                    )
                    EngineTranscription(
                        text = output.text,
                        latencyMs = (output.processingSeconds * 1000.0).toLong(),
                        audioSec = output.audioSeconds,
                        usedNativeStreaming = output.usedNativeStream,
                        usedChunkFallback = output.fellBackToChunk
                    )
                } else {
                    val output = transcribeRunAnywhereClipWithChunkFallback(
                        samples = samples,
                        sampleRate = sampleRate,
                        model = model,
                        language = state.language,
                        detectLanguage = state.detectLanguage
                    )
                    EngineTranscription(
                        text = output.text,
                        latencyMs = (output.processingSeconds * 1000.0).toLong(),
                        audioSec = output.audioSeconds
                    )
                }
            }
        }
    }

    private suspend fun transcribeRunAnywhereClipWithChunkFallback(
        samples: FloatArray,
        sampleRate: Int,
        model: EngineModel,
        language: String,
        detectLanguage: Boolean
    ): RunAnywhereClipResult {
        val maxSecondsPerCall = 29.5
        val totalAudioSec = if (sampleRate > 0) samples.size.toDouble() / sampleRate.toDouble() else 0.0
        if (totalAudioSec <= maxSecondsPerCall) {
            return runAnywhereEngine.transcribe(samples, sampleRate, model, language, detectLanguage)
        }

        val chunkSeconds = 25.0
        val overlapSeconds = 1.0
        val chunkSamples = (chunkSeconds * sampleRate).toInt().coerceAtLeast(sampleRate)
        val overlapSamples = (overlapSeconds * sampleRate).toInt().coerceAtLeast(0)

        var index = 0
        var mergedText = ""
        var totalProcessing = 0.0

        while (index < samples.size) {
            val end = min(samples.size, index + chunkSamples)
            val chunk = samples.copyOfRange(index, end)
            val output = runAnywhereEngine.transcribe(chunk, sampleRate, model, language, detectLanguage)
            mergedText = mergeStreamingText(mergedText, output.text)
            totalProcessing += output.processingSeconds

            if (end >= samples.size) {
                break
            }
            index = (end - overlapSamples).coerceAtLeast(index + 1)
        }

        return RunAnywhereClipResult(
            text = mergedText.trim(),
            processingSeconds = totalProcessing,
            audioSeconds = totalAudioSec
        )
    }

    private fun applyTranscriptionResult(result: EngineTranscription, replaceText: Boolean) {
        val nextText = if (replaceText) {
            result.text
        } else {
            mergeStreamingText(_uiState.value.transcription, result.text)
        }

        updatePerformance(result.latencyMs, result.audioSec)
        updateUi {
            it.copy(
                transcription = nextText
            )
        }
    }

    private fun updatePerformance(latencyMs: Long, audioSec: Double) {
        if (audioSec <= 0.0) return
        val rtf = latencyMs / 1000.0 / audioSec

        totalLatencyMs += latencyMs
        totalRtf += rtf
        statsCount += 1

        updateUi {
            it.copy(
                performance = PerformanceStats(
                    lastLatencyMs = latencyMs,
                    avgLatencyMs = if (statsCount > 0) totalLatencyMs / statsCount else latencyMs,
                    lastAudioSec = audioSec.toFloat(),
                    lastRtf = rtf.toFloat(),
                    avgRtf = if (statsCount > 0) (totalRtf / statsCount).toFloat() else rtf.toFloat()
                )
            )
        }
    }

    private fun chunkConfig(state: AppUiState): ChunkConfig {
        return when (state.sttEngine) {
            SttEngineType.WHISPER -> ChunkConfig(chunkSeconds = 4.0f, overlapSeconds = 1.0f)
            SttEngineType.NEXA -> ChunkConfig(
                chunkSeconds = state.nexaChunkSeconds,
                overlapSeconds = state.nexaOverlapSeconds
            )
            SttEngineType.RUN_ANYWHERE -> ChunkConfig(
                chunkSeconds = state.runAnywhereChunkSeconds,
                overlapSeconds = state.runAnywhereOverlapSeconds
            )
        }
    }

    private fun selectedModel(state: AppUiState): EngineModel {
        return when (state.sttEngine) {
            SttEngineType.WHISPER -> {
                SherpaOnnxModelCatalog.models.find { it.id == state.sherpaModelId }
                    ?: SherpaOnnxModelCatalog.models.first()
            }
            SttEngineType.NEXA -> {
                NexaModelCatalog.models.find { it.id == state.nexaModelId }
                    ?: NexaModelCatalog.models.first()
            }
            SttEngineType.RUN_ANYWHERE -> {
                RunAnywhereModelCatalog.models.find { it.id == state.runAnywhereModelId }
                    ?: RunAnywhereModelCatalog.models.first()
            }
        }
    }

    private fun selectedModelKey(state: AppUiState): String {
        return when (state.sttEngine) {
            SttEngineType.WHISPER -> "sherpa:${state.sherpaModelId}:${state.language}"
            SttEngineType.NEXA -> "nexa:${state.nexaModelId}:${state.language}"
            SttEngineType.RUN_ANYWHERE -> "runanywhere:${state.runAnywhereModelId}"
        }
    }

    private fun invalidateModelInit(message: String) {
        modelReadyKey = null
        updateUi {
            it.copy(
                modelInitState = ModelInitState.NOT_INITIALIZED,
                modelInitMessage = message
            )
        }
    }

    private fun startRecording(onChunk: (FloatArray) -> Unit) {
        recordJob?.cancel()

        val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            .coerceAtLeast(sampleRate)

        val record = createAudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, minBuffer)
            ?: createAudioRecord(MediaRecorder.AudioSource.MIC, minBuffer)

        if (record == null) {
            updateUi {
                it.copy(
                    isListening = false,
                    status = "AudioRecord init failed"
                )
            }
            log("AudioRecord init failed", toast = true)
            return
        }

        audioRecord = record
        enableAudioEffects(record)
        record.startRecording()

        recordJob = viewModelScope.launch(Dispatchers.IO) {
            val shortBuffer = ShortArray(minBuffer / 2)
            while (_uiState.value.isListening) {
                val read = audioRecord?.read(shortBuffer, 0, shortBuffer.size) ?: 0
                if (read > 0) {
                    onChunk(AudioUtils.shortToFloat(shortBuffer, read))
                }
            }
        }
    }

    private fun stopRecording() {
        updateUi { it.copy(isListening = false) }
        recordJob?.cancel()
        recordJob = null

        releaseAudioEffects()
        audioRecord?.let { record ->
            runCatching { record.stop() }
            runCatching { record.release() }
        }
        audioRecord = null
    }

    private fun appendStreamWindow(chunk: FloatArray) {
        synchronized(streamWindowLock) {
            streamWindowChunks.addLast(chunk)
            streamWindowSamples += chunk.size
        }
    }

    private fun snapshotStreamWindow(): FloatArray {
        synchronized(streamWindowLock) {
            val output = FloatArray(streamWindowSamples)
            var index = 0
            for (chunk in streamWindowChunks) {
                System.arraycopy(chunk, 0, output, index, chunk.size)
                index += chunk.size
            }
            return output
        }
    }

    private fun trimStreamWindow(keepSamples: Int) {
        synchronized(streamWindowLock) {
            if (keepSamples <= 0) {
                streamWindowChunks.clear()
                streamWindowSamples = 0
                return
            }

            val reversed = streamWindowChunks.toList().asReversed()
            val kept = ArrayDeque<FloatArray>()
            var remaining = keepSamples

            for (chunk in reversed) {
                if (remaining <= 0) break
                if (chunk.size <= remaining) {
                    kept.addFirst(chunk)
                    remaining -= chunk.size
                } else {
                    val tail = chunk.copyOfRange(chunk.size - remaining, chunk.size)
                    kept.addFirst(tail)
                    remaining = 0
                }
            }

            streamWindowChunks.clear()
            streamWindowChunks.addAll(kept)
            streamWindowSamples = keepSamples - remaining
        }
    }

    private fun currentWindowSamples(): Int {
        synchronized(streamWindowLock) {
            return streamWindowSamples
        }
    }

    private fun flattenFloatChunks(chunks: List<FloatArray>): FloatArray {
        val total = chunks.sumOf { it.size }
        val out = FloatArray(total)
        var index = 0
        for (chunk in chunks) {
            System.arraycopy(chunk, 0, out, index, chunk.size)
            index += chunk.size
        }
        return out
    }

    private fun mergeStreamingText(existing: String, incoming: String): String {
        val cleanIncoming = incoming.trim()
        if (cleanIncoming.isEmpty()) return existing

        val cleanExisting = existing.trim()
        if (cleanExisting.isEmpty()) return cleanIncoming

        val existingWords = cleanExisting.split("\\s+".toRegex())
        val incomingWords = cleanIncoming.split("\\s+".toRegex())
        val maxOverlap = min(8, min(existingWords.size, incomingWords.size))

        for (k in maxOverlap downTo 1) {
            val suffix = existingWords.takeLast(k).joinToString(" ")
            val prefix = incomingWords.take(k).joinToString(" ")
            if (suffix.equals(prefix, ignoreCase = true)) {
                return (existingWords.dropLast(k) + incomingWords).joinToString(" ")
            }
        }
        return "$cleanExisting $cleanIncoming"
    }

    private fun createAudioRecord(source: Int, bufferSize: Int): AudioRecord? {
        return try {
            val record = AudioRecord(source, sampleRate, channelConfig, audioFormat, bufferSize)
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                null
            } else {
                record
            }
        } catch (e: Exception) {
            Log.e(tag, "AudioRecord init error: ${e.message}")
            null
        }
    }

    private fun enableAudioEffects(record: AudioRecord) {
        val sessionId = record.audioSessionId
        if (sessionId == AudioRecord.ERROR || sessionId == AudioRecord.ERROR_BAD_VALUE) return

        if (NoiseSuppressor.isAvailable()) {
            noiseSuppressor = NoiseSuppressor.create(sessionId)
            noiseSuppressor?.enabled = true
        }
        if (AcousticEchoCanceler.isAvailable()) {
            echoCanceler = AcousticEchoCanceler.create(sessionId)
            echoCanceler?.enabled = true
        }
        if (AutomaticGainControl.isAvailable()) {
            agc = AutomaticGainControl.create(sessionId)
            agc?.enabled = true
        }
    }

    private fun releaseAudioEffects() {
        noiseSuppressor?.release()
        echoCanceler?.release()
        agc?.release()
        noiseSuppressor = null
        echoCanceler = null
        agc = null
    }

    private fun ensureTts() {
        if (tts != null) return

        tts = TextToSpeech(getApplication()) { status ->
            val success = status == TextToSpeech.SUCCESS
            updateUi { it.copy(ttsReady = success) }
            if (!success) {
                log("TTS initialization failed", toast = true)
                return@TextToSpeech
            }

            tts?.language = Locale.getDefault()
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    updateUi { it.copy(isSpeaking = true) }
                }

                override fun onDone(utteranceId: String?) {
                    updateUi {
                        it.copy(
                            isSpeaking = false,
                            status = "Idle"
                        )
                    }
                }

                override fun onError(utteranceId: String?) {
                    updateUi {
                        it.copy(
                            isSpeaking = false,
                            status = "TTS error"
                        )
                    }
                    log("TTS error", toast = true)
                }
            })
        }
    }

    private fun languageHintForClip(clip: BenchmarkClip): LanguageHint {
        return when (clip.id) {
            "fleurs_ja_clip_4" -> LanguageHint(language = "ja", detectLanguage = false)
            "fleurs_zh_clip_5" -> LanguageHint(language = "zh", detectLanguage = false)
            "fleurs_zh_en_mix_clip_6" -> LanguageHint(language = "auto", detectLanguage = true)
            else -> LanguageHint(language = "en", detectLanguage = false)
        }
    }

    private fun updateUi(transform: (AppUiState) -> AppUiState) {
        _uiState.update(transform)
    }

    private fun log(message: String, toast: Boolean = false) {
        Log.d(tag, message)
        if (toast) {
            toastFlow.tryEmit(message)
        }
    }

    override fun onCleared() {
        super.onCleared()
        stopRecording()
        sherpaEngine.close()
        nexaEngine.close()
        tts?.stop()
        tts?.shutdown()
        tts = null
    }
}
