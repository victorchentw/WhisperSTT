package com.whisperandroid

enum class AppMode {
    STT,
    TTS,
    BENCHMARK
}

enum class SttMode {
    CLIP,
    STREAMING
}

enum class SttEngineType(val displayName: String) {
    WHISPER("Sherpa-ONNX"),
    NEXA("Nexa SDK"),
    RUN_ANYWHERE("RunAnywhere")
}

enum class ModelInitState {
    NOT_INITIALIZED,
    INITIALIZING,
    READY,
    FAILED
}

data class PerformanceStats(
    val lastLatencyMs: Long = 0,
    val avgLatencyMs: Long = 0,
    val lastAudioSec: Float = 0f,
    val lastRtf: Float = 0f,
    val avgRtf: Float = 0f
)

data class EngineModel(
    val id: String,
    val displayName: String,
    val assetFolderOrFile: String
)

data class BenchmarkClip(
    val id: String,
    val displayName: String,
    val audioAssetPath: String,
    val transcriptAssetPath: String
)

data class BenchmarkResult(
    val engine: String,
    val model: String,
    val mode: String = "Clip",
    val text: String = "",
    val latencyMs: Long? = null,
    val audioDurationSec: Double? = null,
    val realTimeFactor: Double? = null,
    val wer: Double? = null,
    val cer: Double? = null,
    val error: String? = null
)

data class AppUiState(
    val mode: AppMode = AppMode.STT,
    val sttMode: SttMode = SttMode.CLIP,
    val sttEngine: SttEngineType = SttEngineType.WHISPER,
    val status: String = "Idle",
    val modelInitState: ModelInitState = ModelInitState.NOT_INITIALIZED,
    val modelInitMessage: String = "Model not initialized",
    val isListening: Boolean = false,
    val isProcessing: Boolean = false,
    val transcription: String = "",
    val language: String = "auto",
    val detectLanguage: Boolean = true,
    val sherpaModelId: String = SherpaOnnxModelCatalog.models.first().id,
    val nexaModelId: String = NexaModelCatalog.models.first().id,
    val runAnywhereModelId: String = RunAnywhereModelCatalog.models.first().id,
    val nexaChunkSeconds: Float = 4.0f,
    val nexaOverlapSeconds: Float = 1.0f,
    val runAnywhereChunkSeconds: Float = 3.0f,
    val runAnywhereOverlapSeconds: Float = 0.8f,
    val performance: PerformanceStats = PerformanceStats(),
    val ttsText: String = "",
    val isSpeaking: Boolean = false,
    val ttsReady: Boolean = false,
    val benchmarkClipId: String = BenchmarkClipCatalog.clips.first().id,
    val benchmarkTranscriptId: String = BenchmarkClipCatalog.clips.first().id,
    val benchmarkReferenceText: String = "",
    val benchmarkStatus: String = "Ready",
    val benchmarkRunning: Boolean = false,
    val benchmarkIncludeSherpa: Boolean = true,
    val benchmarkIncludeNexa: Boolean = true,
    val benchmarkIncludeRunAnywhere: Boolean = true,
    val benchmarkNexaModelIds: Set<String> = NexaModelCatalog.models.map { it.id }.toSet(),
    val benchmarkRunAnywhereModelIds: Set<String> = RunAnywhereModelCatalog.models.map { it.id }.toSet(),
    val benchmarkResults: List<BenchmarkResult> = emptyList()
)
