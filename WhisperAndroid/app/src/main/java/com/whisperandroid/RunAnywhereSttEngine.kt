package com.whisperandroid

import android.content.Context
import android.util.Log
import com.runanywhere.sdk.core.types.AudioFormat
import com.runanywhere.sdk.core.types.InferenceFramework
import com.runanywhere.sdk.foundation.bridge.extensions.CppBridgeModelRegistry
import com.runanywhere.sdk.public.RunAnywhere
import com.runanywhere.sdk.public.extensions.STT.STTOptions
import com.runanywhere.sdk.public.extensions.loadSTTModel
import com.runanywhere.sdk.public.extensions.transcribeStream
import com.runanywhere.sdk.public.extensions.transcribeWithOptions
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File

data class RunAnywhereChunkResult(
    val text: String,
    val usedNativeStream: Boolean,
    val fellBackToChunk: Boolean,
    val processingSeconds: Double,
    val audioSeconds: Double
)

data class RunAnywhereClipResult(
    val text: String,
    val processingSeconds: Double,
    val audioSeconds: Double
)

class RunAnywhereSttEngine(private val context: Context) {
    private val tag = "RunAnywhere.STT"
    private val lock = Mutex()

    @Volatile
    private var loadedModelId: String? = null
    private val bundleVersion = "runanywhere-model-bundle-v2"

    suspend fun prepareModel(model: EngineModel) = lock.withLock {
        val initResult = WhisperAndroidApp.awaitRunAnywhereInit()
        initResult.getOrElse { throw IllegalStateException("RunAnywhere init failed: ${it.message}") }

        val localModelDir = ensureModelInAppFiles(model)
        registerLocalModel(model, localModelDir)

        if (loadedModelId != model.id) {
            RunAnywhere.loadSTTModel(model.id)
            loadedModelId = model.id
            Log.i(tag, "STT model loaded: ${model.id}")
        }
    }

    suspend fun transcribe(
        samples: FloatArray,
        sampleRate: Int,
        model: EngineModel,
        language: String,
        detectLanguage: Boolean
    ): RunAnywhereClipResult {
        prepareModel(model)
        val audioBytes = AudioUtils.floatToPcm16(samples)
        val options = sttOptions(sampleRate, language, detectLanguage)
        val output = RunAnywhere.transcribeWithOptions(audioBytes, options)
        val audioSec = if (sampleRate > 0) samples.size.toDouble() / sampleRate.toDouble() else 0.0
        return RunAnywhereClipResult(
            text = output.text.trim(),
            processingSeconds = output.metadata.processingTime,
            audioSeconds = audioSec
        )
    }

    suspend fun transcribeStreamingChunk(
        samples: FloatArray,
        sampleRate: Int,
        model: EngineModel,
        language: String,
        detectLanguage: Boolean,
        preferNativeStreaming: Boolean
    ): RunAnywhereChunkResult {
        prepareModel(model)
        val audioBytes = AudioUtils.floatToPcm16(samples)
        val options = sttOptions(sampleRate, language, detectLanguage)
        val audioSec = if (sampleRate > 0) samples.size.toDouble() / sampleRate.toDouble() else 0.0

        if (preferNativeStreaming) {
            try {
                var partialText = ""
                val output = RunAnywhere.transcribeStream(audioBytes, options) { partial ->
                    if (partial.transcript.isNotBlank()) {
                        partialText = partial.transcript.trim()
                    }
                }
                val finalText = output.text.trim().ifEmpty { partialText }
                if (finalText.isNotEmpty()) {
                    return RunAnywhereChunkResult(
                        text = finalText,
                        usedNativeStream = true,
                        fellBackToChunk = false,
                        processingSeconds = output.metadata.processingTime,
                        audioSeconds = audioSec
                    )
                }
            } catch (e: Exception) {
                Log.w(tag, "Native stream failed, fallback to chunk: ${e.message}")
            }
        }

        val fallback = RunAnywhere.transcribeWithOptions(audioBytes, options)
        return RunAnywhereChunkResult(
            text = fallback.text.trim(),
            usedNativeStream = false,
            fellBackToChunk = true,
            processingSeconds = fallback.metadata.processingTime,
            audioSeconds = audioSec
        )
    }

    private fun sttOptions(sampleRate: Int, language: String, detectLanguage: Boolean): STTOptions {
        val normalizedLanguage = when {
            detectLanguage -> "auto"
            language.isBlank() -> "auto"
            language.equals("auto", ignoreCase = true) -> "auto"
            else -> language.trim().lowercase()
        }
        return STTOptions(
            language = normalizedLanguage,
            detectLanguage = detectLanguage,
            audioFormat = AudioFormat.PCM,
            sampleRate = sampleRate,
            preferredFramework = InferenceFramework.ONNX
        )
    }

    private fun ensureModelInAppFiles(model: EngineModel): File {
        val destination = File(context.filesDir, "whisperandroid/models/runanywhere/${model.id}")
        val marker = File(destination, ".synced.version")
        val encoder = File(destination, "encoder.onnx")
        val decoder = File(destination, "decoder.onnx")
        val tokens = File(destination, "tokens.txt")

        val hasValidBundle = destination.exists() &&
            marker.exists() &&
            marker.readText().trim() == bundleVersion &&
            encoder.exists() && encoder.length() > 1_000_000L &&
            decoder.exists() && decoder.length() > 1_000_000L &&
            tokens.exists() && tokens.length() > 10_000L

        if (hasValidBundle) {
            return destination
        }

        if (destination.exists()) {
            destination.deleteRecursively()
        }

        if (!AssetUtils.assetExists(context, model.assetFolderOrFile)) {
            throw IllegalStateException(
                "Bundled RunAnywhere model missing in assets: ${model.assetFolderOrFile}. " +
                    "Run ./scripts/bootstrap_android_models.sh and rebuild."
            )
        }

        AssetUtils.copyAssetPathToFileSystem(context, model.assetFolderOrFile, destination)

        // Validate copied files before exposing the directory to native loader.
        if (!encoder.exists() || !decoder.exists() || !tokens.exists()) {
            val listed = destination.listFiles()?.joinToString(", ") { it.name } ?: "(empty)"
            throw IllegalStateException(
                "Copied RunAnywhere model is incomplete: ${model.id}. " +
                    "Expected encoder.onnx/decoder.onnx/tokens.txt, found: $listed"
            )
        }

        marker.writeText(bundleVersion)
        Log.i(
            tag,
            "Prepared local model ${model.id}: encoder=${encoder.length()} decoder=${decoder.length()} tokens=${tokens.length()}"
        )
        return destination
    }

    private fun registerLocalModel(model: EngineModel, localModelDir: File) {
        val modelInfo = CppBridgeModelRegistry.ModelInfo(
            modelId = model.id,
            name = model.displayName,
            category = CppBridgeModelRegistry.ModelCategory.SPEECH_RECOGNITION,
            format = CppBridgeModelRegistry.ModelFormat.ONNX,
            framework = CppBridgeModelRegistry.Framework.ONNX,
            downloadUrl = null,
            localPath = localModelDir.absolutePath,
            downloadSize = 0L,
            contextLength = 0,
            supportsThinking = false,
            description = "Bundled RunAnywhere ONNX model",
            status = CppBridgeModelRegistry.ModelStatus.DOWNLOADED
        )
        CppBridgeModelRegistry.save(modelInfo)
    }
}
