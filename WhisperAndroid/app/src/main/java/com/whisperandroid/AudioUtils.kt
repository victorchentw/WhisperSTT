package com.whisperandroid

import android.content.Context
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.min

object AudioUtils {
    fun shortToFloat(buffer: ShortArray, size: Int): FloatArray {
        val out = FloatArray(size)
        for (i in 0 until size) {
            out[i] = buffer[i] / 32768.0f
        }
        return out
    }

    fun floatToPcm16(samples: FloatArray): ByteArray {
        val out = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { sample ->
            val clamped = max(-1f, min(1f, sample))
            out.putShort((clamped * 32767.0f).toInt().toShort())
        }
        return out.array()
    }

    fun pcm16ToFloat(data: ByteArray): FloatArray {
        val count = data.size / 2
        val out = FloatArray(count)
        val bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until count) {
            out[i] = bb.short / 32768.0f
        }
        return out
    }

    fun writeWavTemp(
        context: Context,
        samples: FloatArray,
        sampleRate: Int = 16000,
        prefix: String = "audio"
    ): File {
        val pcm16 = floatToPcm16(samples)
        val wavData = buildWav(pcm16, sampleRate, channels = 1, bitsPerSample = 16)
        val file = File(context.cacheDir, "${prefix}_${System.currentTimeMillis()}.wav")
        FileOutputStream(file).use { it.write(wavData) }
        return file
    }

    fun readWavFromAssets(context: Context, assetPath: String): Pair<FloatArray, Int> {
        val bytes = context.assets.open(assetPath).use { it.readBytes() }
        if (bytes.size < 44) {
            throw IllegalArgumentException("Invalid WAV: file too small")
        }

        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val riff = String(bytes.copyOfRange(0, 4))
        val wave = String(bytes.copyOfRange(8, 12))
        if (riff != "RIFF" || wave != "WAVE") {
            throw IllegalArgumentException("Invalid WAV header: $assetPath")
        }

        var offset = 12
        var sampleRate = 16000
        var bitsPerSample = 16
        var channels = 1
        var dataOffset = -1
        var dataSize = 0

        while (offset + 8 <= bytes.size) {
            val chunkId = String(bytes.copyOfRange(offset, offset + 4))
            val chunkSize = bb.getInt(offset + 4)
            val chunkDataStart = offset + 8

            if (chunkId == "fmt " && chunkSize >= 16) {
                val audioFormat = bb.getShort(chunkDataStart).toInt()
                channels = bb.getShort(chunkDataStart + 2).toInt()
                sampleRate = bb.getInt(chunkDataStart + 4)
                bitsPerSample = bb.getShort(chunkDataStart + 14).toInt()
                if (audioFormat != 1) {
                    throw IllegalArgumentException("Only PCM WAV is supported: $assetPath")
                }
            } else if (chunkId == "data") {
                dataOffset = chunkDataStart
                dataSize = chunkSize
                break
            }

            offset = chunkDataStart + chunkSize
            if (offset and 1 == 1) {
                offset += 1
            }
        }

        if (dataOffset < 0 || dataOffset + dataSize > bytes.size) {
            throw IllegalArgumentException("WAV data chunk not found: $assetPath")
        }
        if (bitsPerSample != 16) {
            throw IllegalArgumentException("Only 16-bit WAV is supported: $assetPath")
        }

        val rawPcm = bytes.copyOfRange(dataOffset, dataOffset + dataSize)
        val monoPcm = if (channels == 1) {
            rawPcm
        } else {
            downmixToMonoPcm16(rawPcm, channels)
        }
        return pcm16ToFloat(monoPcm) to sampleRate
    }

    private fun downmixToMonoPcm16(rawPcm: ByteArray, channels: Int): ByteArray {
        val inBuffer = ByteBuffer.wrap(rawPcm).order(ByteOrder.LITTLE_ENDIAN)
        val frameCount = rawPcm.size / (channels * 2)
        val out = ByteArrayOutputStream(frameCount * 2)

        repeat(frameCount) {
            var acc = 0
            repeat(channels) {
                acc += inBuffer.short.toInt()
            }
            val mixed = (acc / channels).toShort()
            out.write((mixed.toInt() and 0xFF))
            out.write(((mixed.toInt() shr 8) and 0xFF))
        }
        return out.toByteArray()
    }

    private fun buildWav(
        pcm16: ByteArray,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ): ByteArray {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val blockAlign = channels * bitsPerSample / 8
        val totalDataLen = 36 + pcm16.size

        val bb = ByteBuffer.allocate(44 + pcm16.size).order(ByteOrder.LITTLE_ENDIAN)
        bb.put("RIFF".toByteArray(Charsets.US_ASCII))
        bb.putInt(totalDataLen)
        bb.put("WAVE".toByteArray(Charsets.US_ASCII))
        bb.put("fmt ".toByteArray(Charsets.US_ASCII))
        bb.putInt(16)
        bb.putShort(1) // PCM
        bb.putShort(channels.toShort())
        bb.putInt(sampleRate)
        bb.putInt(byteRate)
        bb.putShort(blockAlign.toShort())
        bb.putShort(bitsPerSample.toShort())
        bb.put("data".toByteArray(Charsets.US_ASCII))
        bb.putInt(pcm16.size)
        bb.put(pcm16)
        return bb.array()
    }
}
