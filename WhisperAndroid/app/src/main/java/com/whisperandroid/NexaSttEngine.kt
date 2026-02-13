package com.whisperandroid

import android.content.Context
import android.util.Log
import com.nexa.sdk.AsrWrapper
import com.nexa.sdk.NexaSdk
import com.nexa.sdk.bean.AsrConfig
import com.nexa.sdk.bean.AsrCreateInput
import com.nexa.sdk.bean.AsrTranscribeInput
import com.nexa.sdk.bean.ModelConfig
import com.nexa.sdk.bean.PluginIdValue
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import kotlin.coroutines.resume

data class NexaClipResult(
    val text: String,
    val processingSeconds: Double,
    val audioSeconds: Double
)

class NexaSttEngine(private val context: Context) {
    private val tag = "Nexa.STT"
    private val lock = Mutex()

    @Volatile
    private var asrWrapper: AsrWrapper? = null
    @Volatile
    private var loadedModelPath: String? = null

    suspend fun prepareModel(model: EngineModel, language: String) {
        lock.withLock {
            initializeSdkIfNeeded()
            val localModelFile = ensureModelInAppFiles(model)
            if (loadedModelPath == localModelFile.absolutePath && asrWrapper != null) {
                return@withLock
            }

            asrWrapper?.close()
            val plugin = resolvePlugin(model)
            val createInput = AsrCreateInput(
                model_name = model.id,
                model_path = localModelFile.absolutePath,
                tokenizer_path = "",
                config = ModelConfig(),
                language = normalizeLanguage(language),
                plugin_id = plugin.value,
                device_id = "",
                license_id = "",
                license_key = ""
            )

            val built = AsrWrapper.builder()
                .asrCreateInput(createInput)
                .build()
                .getOrElse { throw IllegalStateException("Nexa build failed: ${it.message}") }

            asrWrapper = built
            loadedModelPath = localModelFile.absolutePath
            Log.i(tag, "Nexa model loaded: ${model.displayName}")
        }
    }

    suspend fun transcribe(
        samples: FloatArray,
        sampleRate: Int,
        model: EngineModel,
        language: String
    ): NexaClipResult {
        prepareModel(model, language)
        val wrapper = asrWrapper ?: error("Nexa wrapper is not initialized")
        val wav = AudioUtils.writeWavTemp(context, samples, sampleRate, "nexa")
        val startMs = System.currentTimeMillis()
        return try {
            val output = wrapper.transcribe(
                AsrTranscribeInput(
                    audioPath = wav.absolutePath,
                    language = normalizeLanguage(language),
                    config = AsrConfig(stream = false)
                )
            ).getOrElse { throw IllegalStateException("Nexa transcribe failed: ${it.message}") }

            val elapsedSec = (System.currentTimeMillis() - startMs) / 1000.0
            val audioSec = if (sampleRate > 0) samples.size.toDouble() / sampleRate.toDouble() else 0.0
            NexaClipResult(
                text = output.result?.transcript?.trim().orEmpty(),
                processingSeconds = elapsedSec,
                audioSeconds = audioSec
            )
        } finally {
            wav.delete()
        }
    }

    fun close() {
        asrWrapper?.close()
        asrWrapper = null
        loadedModelPath = null
    }

    private suspend fun initializeSdkIfNeeded() {
        if (isNexaInitialized) return
        suspendCancellableCoroutine { continuation ->
            val sdk = NexaSdk.Companion.getInstance()
            sdk.init(
                context,
                object : NexaSdk.InitCallback {
                    override fun onSuccess() {
                        isNexaInitialized = true
                        continuation.resume(Unit)
                    }

                    override fun onFailure(error: String) {
                        continuation.resume(Unit)
                        Log.w(tag, "Nexa init failure: $error")
                    }
                }
            )
        }
    }

    private fun resolvePlugin(model: EngineModel): PluginIdValue {
        return if (model.id.contains("npu", ignoreCase = true)) {
            PluginIdValue.NPU
        } else {
            PluginIdValue.WHISPER_CPP
        }
    }

    private fun ensureModelInAppFiles(model: EngineModel): File {
        val destination = File(context.filesDir, "whisperandroid/models/nexa/${model.id}")
        val isAssetFile = model.assetFolderOrFile.contains(".")
        if (isAssetFile) {
            val fileName = File(model.assetFolderOrFile).name
            val destinationFile = File(destination, fileName)
            if (!destinationFile.exists()) {
                destination.mkdirs()
                AssetUtils.copyAssetPathToFileSystem(context, model.assetFolderOrFile, destinationFile)
            }
            return destinationFile
        }

        if (!destination.exists()) {
            AssetUtils.copyAssetPathToFileSystem(context, model.assetFolderOrFile, destination)
        }
        return destination
    }

    private fun normalizeLanguage(language: String): String {
        val code = language.trim().lowercase()
        if (code.isEmpty() || code == "auto") return "en"
        return code.substringBefore('-')
    }

    companion object {
        @Volatile
        private var isNexaInitialized = false
    }
}
