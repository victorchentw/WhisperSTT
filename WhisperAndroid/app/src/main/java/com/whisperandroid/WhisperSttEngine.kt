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
    private val tag = "WhisperAndroid"
    private val decodeMutex = Mutex()
    @Volatile
    private var recognizer: OfflineRecognizer? = null
    @Volatile
    private var currentLanguage: String = ""

    private fun normalizeLanguage(language: String): String {
        val code = language.trim().lowercase()
        if (code.isEmpty() || code == "auto") return ""
        val normalized = code.replace('_', '-')
        return normalized.substringBefore('-')
    }

    private fun buildRecognizer(language: String): OfflineRecognizer {
        val whisper = OfflineWhisperModelConfig().apply {
            encoder = "models/whisper/tiny/tiny-encoder.onnx"
            decoder = "models/whisper/tiny/tiny-decoder.onnx"
            // sherpa-onnx Whisper expects a concrete language code or empty string for auto.
            this.language = language
            task = "transcribe"
            tailPaddings = -1
        }

        val modelConfig = OfflineModelConfig().apply {
            this.whisper = whisper
            tokens = "models/whisper/tiny/tiny-tokens.txt"
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

        val displayLanguage = if (language.isEmpty()) "auto" else language
        Log.d(tag, "Initializing OfflineRecognizer (Whisper tiny, multilingual, language=$displayLanguage)")
        return OfflineRecognizer(context.assets, config)
    }

    suspend fun transcribe(samples: FloatArray, sampleRate: Int, language: String): String = decodeMutex.withLock {
        if (samples.isEmpty()) return ""
        val normalizedLanguage = normalizeLanguage(language)
        val rec = if (recognizer == null || currentLanguage != normalizedLanguage) {
            recognizer?.release()
            buildRecognizer(normalizedLanguage).also {
                recognizer = it
                currentLanguage = normalizedLanguage
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
    }
}
