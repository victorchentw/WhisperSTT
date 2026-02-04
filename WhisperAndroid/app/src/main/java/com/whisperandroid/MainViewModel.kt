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
import kotlinx.coroutines.launch
import java.util.Locale
import kotlin.math.min

enum class MainMode { STT, TTS }

enum class SttMode { STREAMING, CLIP }

data class PerformanceStats(
    val lastLatencyMs: Long = 0,
    val avgLatencyMs: Long = 0,
    val lastAudioSec: Float = 0f,
    val lastRtf: Float = 0f,
    val avgRtf: Float = 0f
)

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val tag = "WhisperAndroid"
    private val sttEngine = WhisperSttEngine(application)

    private val sampleRate = 16000
    private val channelConfig = AudioFormat.CHANNEL_IN_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_16BIT

    private val supportedLanguages = listOf("auto", "en", "zh", "ja", "ko", "fr", "de", "es")

    private val _mode = MutableStateFlow(MainMode.STT)
    val mode: StateFlow<MainMode> = _mode

    private val _sttMode = MutableStateFlow(SttMode.CLIP)
    val sttMode: StateFlow<SttMode> = _sttMode

    private val _status = MutableStateFlow("Idle")
    val status: StateFlow<String> = _status

    private val _isListening = MutableStateFlow(false)
    val isListening: StateFlow<Boolean> = _isListening

    private val _transcription = MutableStateFlow("")
    val transcription: StateFlow<String> = _transcription

    private val _language = MutableStateFlow(resolveDefaultLanguage())
    val language: StateFlow<String> = _language
    val languageOptions: List<String> = supportedLanguages

    private val _performance = MutableStateFlow(PerformanceStats())
    val performance: StateFlow<PerformanceStats> = _performance

    private val _ttsText = MutableStateFlow("")
    val ttsText: StateFlow<String> = _ttsText

    private val _isSpeaking = MutableStateFlow(false)
    val isSpeaking: StateFlow<Boolean> = _isSpeaking

    private val _ttsReady = MutableStateFlow(false)
    val ttsReady: StateFlow<Boolean> = _ttsReady

    val toastFlow = MutableSharedFlow<String>(extraBufferCapacity = 1)

    private var tts: TextToSpeech? = null
    private var audioRecord: AudioRecord? = null
    private var recordJob: Job? = null
    private var decodeJob: Job? = null
    private var noiseSuppressor: NoiseSuppressor? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var agc: AutomaticGainControl? = null

    private val clipChunks = mutableListOf<ShortArray>()
    private val clipChunkSizes = mutableListOf<Int>()

    private val streamWindowChunks = ArrayDeque<FloatArray>()
    private var streamWindowSamples = 0
    private val streamWindowLock = Any()

    private val streamFullChunks = mutableListOf<FloatArray>()

    private var totalLatencyMs = 0L
    private var totalRtf = 0f
    private var statsCount = 0

    private val streamSegmentSeconds = 4.0f
    private val streamOverlapSeconds = 1.0f

    fun setMode(newMode: MainMode) {
        _mode.value = newMode
    }

    fun setSttMode(newMode: SttMode) {
        _sttMode.value = newMode
    }

    fun updateTtsText(text: String) {
        _ttsText.value = text
    }

    fun setLanguage(code: String) {
        _language.value = code
    }

    fun startClip() {
        if (_isListening.value) return
        clipChunks.clear()
        clipChunkSizes.clear()
        _isListening.value = true
        _status.value = "Listening (clip)"
        log("Start clip recording", true)

        startRecording { buffer, read ->
            if (read > 0) {
                clipChunks.add(buffer.copyOf(read))
                clipChunkSizes.add(read)
            }
        }
    }

    fun stopClipAndTranscribe() {
        if (!_isListening.value) return
        stopRecording()
        _isListening.value = false
        _status.value = "Transcribing (clip)"
        log("Stop clip recording, transcribing", true)

        val samples = flattenShortChunks(clipChunks, clipChunkSizes)
        if (samples.isEmpty()) {
            _status.value = "Idle"
            log("No audio captured")
            return
        }

        decodeJob?.cancel()
        decodeJob = viewModelScope.launch(Dispatchers.Default) {
            val (text, latencyMs, audioSec) = transcribeWithStats(samples)
            _transcription.value = text
            updatePerformance(latencyMs, audioSec)
            _status.value = "Idle"
            log("Transcription finished (${latencyMs} ms)")
        }
    }

    fun startStreaming() {
        if (_isListening.value) return
        _isListening.value = true
        _status.value = "Listening (streaming)"
        _transcription.value = ""
        log("Start streaming", true)

        synchronized(streamWindowLock) {
            streamWindowChunks.clear()
            streamWindowSamples = 0
        }
        streamFullChunks.clear()

        startRecording { buffer, read ->
            if (read <= 0) return@startRecording
            val floatChunk = toFloatArray(buffer, read)
            streamFullChunks.add(floatChunk)
            appendStreamWindow(floatChunk)

            val windowSamples = (streamSegmentSeconds * sampleRate).toInt()
            if (currentWindowSamples() >= windowSamples) {
                val snapshot = snapshotStreamWindow()
                if (snapshot.isNotEmpty()) {
                    val scheduled = decodeStreamingSnapshot(snapshot)
                    if (scheduled) {
                        trimStreamWindow((streamOverlapSeconds * sampleRate).toInt())
                    }
                }
            }
        }
    }

    fun stopStreaming() {
        if (!_isListening.value) return
        stopRecording()
        _isListening.value = false
        _status.value = "Transcribing (final)"
        log("Stop streaming, final transcription", true)

        val samples = flattenFloatChunks(streamFullChunks)
        if (samples.isEmpty()) {
            _status.value = "Idle"
            return
        }

        decodeJob?.cancel()
        decodeJob = viewModelScope.launch(Dispatchers.Default) {
            val (text, latencyMs, audioSec) = transcribeWithStats(samples)
            _transcription.value = text
            updatePerformance(latencyMs, audioSec)
            _status.value = "Idle"
            log("Final transcription finished (${latencyMs} ms)")
        }
    }

    private fun decodeStreamingSnapshot(snapshot: FloatArray): Boolean {
        if (decodeJob?.isActive == true) return false
        decodeJob = viewModelScope.launch(Dispatchers.Default) {
            val (text, latencyMs, audioSec) = transcribeWithStats(snapshot)
            _transcription.value = mergeStreamingText(_transcription.value, text)
            updatePerformance(latencyMs, audioSec)
        }
        return true
    }

    fun startSpeaking() {
        val text = _ttsText.value.trim()
        if (text.isEmpty()) {
            log("TTS text is empty", true)
            return
        }
        ensureTts()
        if (_ttsReady.value.not()) {
            log("TTS not ready", true)
            return
        }
        _status.value = "Speaking"
        log("TTS speak", true)
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "utterance")
    }

    fun stopSpeaking() {
        tts?.stop()
        _isSpeaking.value = false
        _status.value = "Idle"
        log("TTS stop")
    }

    private fun ensureTts() {
        if (tts != null) return
        tts = TextToSpeech(getApplication()) { status ->
            val ready = status == TextToSpeech.SUCCESS
            _ttsReady.value = ready
            if (ready) {
                tts?.language = Locale.getDefault()
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) {
                        _isSpeaking.value = true
                    }

                    override fun onDone(utteranceId: String?) {
                        _isSpeaking.value = false
                        _status.value = "Idle"
                    }

                    override fun onError(utteranceId: String?) {
                        _isSpeaking.value = false
                        _status.value = "Idle"
                        log("TTS error", true)
                    }
                })
            } else {
                log("TTS init failed", true)
            }
        }
    }

    private fun startRecording(onPcm: (ShortArray, Int) -> Unit) {
        recordJob?.cancel()
        val minBuffer = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
            .coerceAtLeast(sampleRate)
        val record = createAudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, minBuffer)
            ?: createAudioRecord(MediaRecorder.AudioSource.MIC, minBuffer)
        if (record == null) {
            log("AudioRecord init failed", true)
            _isListening.value = false
            return
        }
        audioRecord = record
        enableAudioEffects(record)
        record.startRecording()

        recordJob = viewModelScope.launch(Dispatchers.IO) {
            val buffer = ShortArray(minBuffer / 2)
            while (_isListening.value) {
                val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                if (read > 0) {
                    onPcm(buffer, read)
                }
            }
        }
    }

    private fun stopRecording() {
        _isListening.value = false
        recordJob?.cancel()
        recordJob = null
        releaseAudioEffects()
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
    }

    private fun toFloatArray(buffer: ShortArray, read: Int): FloatArray {
        val out = FloatArray(read)
        for (i in 0 until read) {
            out[i] = buffer[i] / 32768.0f
        }
        return out
    }

    private fun flattenShortChunks(chunks: List<ShortArray>, sizes: List<Int>): FloatArray {
        val total = sizes.sum()
        val out = FloatArray(total)
        var index = 0
        for (i in chunks.indices) {
            val chunk = chunks[i]
            val size = sizes[i]
            for (j in 0 until size) {
                out[index++] = chunk[j] / 32768.0f
            }
        }
        return out
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

    private suspend fun transcribeWithStats(samples: FloatArray): Triple<String, Long, Float> {
        val start = SystemClock.elapsedRealtime()
        val text = sttEngine.transcribe(samples, sampleRate, _language.value)
        val latencyMs = SystemClock.elapsedRealtime() - start
        val audioSec = samples.size / sampleRate.toFloat()
        return Triple(text, latencyMs, audioSec)
    }

    private fun updatePerformance(latencyMs: Long, audioSec: Float) {
        if (audioSec <= 0f) return
        val rtf = latencyMs / 1000f / audioSec
        totalLatencyMs += latencyMs
        totalRtf += rtf
        statsCount += 1
        _performance.value = PerformanceStats(
            lastLatencyMs = latencyMs,
            avgLatencyMs = totalLatencyMs / statsCount,
            lastAudioSec = audioSec,
            lastRtf = rtf,
            avgRtf = totalRtf / statsCount
        )
    }

    private fun appendStreamWindow(chunk: FloatArray) {
        synchronized(streamWindowLock) {
            streamWindowChunks.addLast(chunk)
            streamWindowSamples += chunk.size
        }
    }

    private fun snapshotStreamWindow(): FloatArray {
        synchronized(streamWindowLock) {
            val out = FloatArray(streamWindowSamples)
            var index = 0
            for (chunk in streamWindowChunks) {
                System.arraycopy(chunk, 0, out, index, chunk.size)
                index += chunk.size
            }
            return out
        }
    }

    private fun trimStreamWindow(keepSamples: Int) {
        synchronized(streamWindowLock) {
            if (keepSamples <= 0) {
                streamWindowChunks.clear()
                streamWindowSamples = 0
                return
            }
            val out = ArrayDeque<FloatArray>()
            var remaining = keepSamples
            val chunks = streamWindowChunks.toList().asReversed()
            for (chunk in chunks) {
                if (remaining <= 0) break
                if (chunk.size <= remaining) {
                    out.addFirst(chunk)
                    remaining -= chunk.size
                } else {
                    val tail = chunk.copyOfRange(chunk.size - remaining, chunk.size)
                    out.addFirst(tail)
                    remaining = 0
                }
            }
            streamWindowChunks.clear()
            streamWindowChunks.addAll(out)
            streamWindowSamples = keepSamples - remaining
        }
    }

    private fun currentWindowSamples(): Int {
        synchronized(streamWindowLock) {
            return streamWindowSamples
        }
    }

    private fun mergeStreamingText(confirmed: String, newText: String): String {
        val cleanNew = newText.trim()
        if (cleanNew.isEmpty()) return confirmed
        val cleanConfirmed = confirmed.trim()
        if (cleanConfirmed.isEmpty()) return cleanNew

        val confirmedWords = cleanConfirmed.split("\\s+".toRegex())
        val newWords = cleanNew.split("\\s+".toRegex())
        val maxCheck = min(6, min(confirmedWords.size, newWords.size))
        for (k in maxCheck downTo 1) {
            val suffix = confirmedWords.takeLast(k).joinToString(" ")
            val prefix = newWords.take(k).joinToString(" ")
            if (suffix.equals(prefix, ignoreCase = true)) {
                val merged = confirmedWords.dropLast(k) + newWords
                return merged.joinToString(" ")
            }
        }
        return "$cleanConfirmed $cleanNew".trim()
    }

    private fun log(message: String, toast: Boolean = false) {
        Log.d(tag, message)
        if (toast) {
            toastFlow.tryEmit(message)
        }
    }

    private fun resolveDefaultLanguage(): String {
        return "auto"
    }

    private fun createAudioRecord(source: Int, bufferSize: Int): AudioRecord? {
        return try {
            val record = AudioRecord(
                source,
                sampleRate,
                channelConfig,
                audioFormat,
                bufferSize
            )
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

    override fun onCleared() {
        super.onCleared()
        stopRecording()
        sttEngine.close()
        tts?.stop()
        tts?.shutdown()
        tts = null
    }
}
