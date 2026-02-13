package com.whisperandroid

import android.content.Context
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.HomophoneReplacerConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class WhisperSttEngine(private val context: Context) {
    private val tag = "WhisperEngine"
    private val decodeMutex = Mutex()

    @Volatile
    private var recognizer: OfflineRecognizer? = null
    @Volatile
    private var currentLanguage = ""
    @Volatile
    private var currentModelAssetPath = SherpaOnnxModelCatalog.models.first().assetFolderOrFile

    private fun normalizeLanguage(language: String): String {
        val code = language.trim().lowercase()
        if (code.isEmpty() || code == "auto") return ""
        return code.replace('_', '-').substringBefore('-')
    }

    suspend fun prepare(modelAssetPath: String, language: String) {
        val normalizedLanguage = normalizeLanguage(language)
        decodeMutex.withLock {
            if (recognizer != null &&
                currentLanguage == normalizedLanguage &&
                currentModelAssetPath == modelAssetPath) {
                return
            }
            recognizer?.release()
            recognizer = buildRecognizer(modelAssetPath, normalizedLanguage)
            currentLanguage = normalizedLanguage
            currentModelAssetPath = modelAssetPath
        }
    }

    private fun buildRecognizer(modelAssetPath: String, language: String): OfflineRecognizer {
        val encoderPath = resolveAssetPath(
            listOf(
                "$modelAssetPath/tiny-encoder.onnx",
                "$modelAssetPath/encoder.onnx",
                "$modelAssetPath/tiny-encoder.int8.onnx"
            )
        )
        val decoderPath = resolveAssetPath(
            listOf(
                "$modelAssetPath/tiny-decoder.onnx",
                "$modelAssetPath/decoder.onnx",
                "$modelAssetPath/tiny-decoder.int8.onnx"
            )
        )
        val tokensPath = resolveAssetPath(
            listOf(
                "$modelAssetPath/tiny-tokens.txt",
                "$modelAssetPath/tokens.txt"
            )
        )

        val whisper = OfflineWhisperModelConfig().apply {
            encoder = encoderPath
            decoder = decoderPath
            this.language = language
            task = "transcribe"
            tailPaddings = -1
        }

        val modelConfig = OfflineModelConfig().apply {
            this.whisper = whisper
            tokens = tokensPath
            modelType = "whisper"
            numThreads = Runtime.getRuntime().availableProcessors().coerceAtMost(4)
            debug = false
        }

        val featConfig = FeatureConfig(16000, 80, 0.0f)

        val config = OfflineRecognizerConfig().apply {
            this.featConfig = featConfig
            this.modelConfig = modelConfig
            this.hr = HomophoneReplacerConfig()
            decodingMethod = "greedy_search"
            maxActivePaths = 0
            hotwordsFile = ""
            hotwordsScore = 1.5f
            ruleFsts = ""
            ruleFars = ""
            blankPenalty = 0.0f
        }

        val displayLanguage = if (language.isBlank()) "auto" else language
        Log.d(tag, "Initializing OfflineRecognizer (language=$displayLanguage, model=$modelAssetPath)")
        return OfflineRecognizer(context.assets, config)
    }

    private fun resolveAssetPath(candidates: List<String>): String {
        for (candidate in candidates) {
            if (assetExists(candidate)) {
                return candidate
            }
        }
        throw IllegalStateException(
            "Sherpa-ONNX model files are missing in Android assets. " +
                "Run ./scripts/bootstrap_android_models.sh and rebuild."
        )
    }

    private fun assetExists(path: String): Boolean {
        return try {
            context.assets.open(path).close()
            true
        } catch (_: Exception) {
            false
        }
    }

    suspend fun transcribe(
        samples: FloatArray,
        sampleRate: Int,
        language: String,
        modelAssetPath: String = SherpaOnnxModelCatalog.models.first().assetFolderOrFile
    ): String = decodeMutex.withLock {
        if (samples.isEmpty()) return ""
        val normalizedLanguage = normalizeLanguage(language)
        val rec = if (recognizer == null ||
            currentLanguage != normalizedLanguage ||
            currentModelAssetPath != modelAssetPath) {
            recognizer?.release()
            buildRecognizer(modelAssetPath, normalizedLanguage).also {
                recognizer = it
                currentLanguage = normalizedLanguage
                currentModelAssetPath = modelAssetPath
            }
        } else {
            recognizer!!
        }
        val stream = rec.createStream()
        try {
            stream.acceptWaveform(samples, sampleRate)
            rec.decode(stream)
            val result = rec.getResult(stream)
            result.text ?: ""
        } finally {
            stream.release()
        }
    }

    fun close() {
        recognizer?.release()
        recognizer = null
        currentLanguage = ""
    }
}
