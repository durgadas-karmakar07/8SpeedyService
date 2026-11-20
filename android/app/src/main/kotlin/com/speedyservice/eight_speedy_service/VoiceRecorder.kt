package com.speedyservice.eight_speedy_service

import android.content.Context
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import java.io.File

/**
 * Records the customer's description of the vehicle problem as a small
 * AAC/M4A file (mono, ~48 kbps → about 360 KB per minute) in the app cache.
 */
class VoiceRecorder(
    private val context: Context,
    private val onLimitReached: () -> Unit,
) {
    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var startedAt = 0L

    val isRecording: Boolean get() = recorder != null

    @Suppress("DEPRECATION")
    fun start(maxDurationMs: Int): String {
        cancel()
        val dir = File(context.cacheDir, DIR).apply { mkdirs() }
        // Old recordings that were never sent.
        dir.listFiles()?.forEach { if (it.lastModified() < System.currentTimeMillis() - DAY_MS) it.delete() }
        val out = File(dir, "voice_${System.currentTimeMillis()}.m4a")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(44100)
            r.setAudioEncodingBitRate(48000)
            r.setMaxDuration(maxDurationMs)
            r.setOutputFile(out.absolutePath)
            r.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) onLimitReached()
            }
            r.prepare()
            r.start()
        } catch (e: Exception) {
            r.release()
            out.delete()
            throw e
        }
        recorder = r
        file = out
        startedAt = SystemClock.elapsedRealtime()
        return out.absolutePath
    }

    /** Returns path + duration, or null if the clip was too short / failed. */
    fun stop(): Map<String, Any>? {
        val r = recorder ?: return null
        val f = file
        val duration = SystemClock.elapsedRealtime() - startedAt
        recorder = null
        file = null
        var ok = true
        try {
            r.stop()
        } catch (_: RuntimeException) {
            ok = false // stop() right after start() -> no valid data
        } finally {
            r.release()
        }
        if (!ok || f == null || !f.exists() || f.length() < 1024 || duration < 800) {
            f?.delete()
            return null
        }
        return mapOf("path" to f.absolutePath, "durationMs" to duration)
    }

    fun cancel() {
        val r = recorder ?: return
        recorder = null
        try {
            r.stop()
        } catch (_: RuntimeException) {
        } finally {
            r.release()
        }
        file?.delete()
        file = null
    }

    /** Peak level since the last call (0..32767), for the live waveform. */
    fun amplitude(): Int = try {
        recorder?.maxAmplitude ?: 0
    } catch (_: Exception) {
        0
    }

    /** Deletes a recording, but only inside our own cache folder. */
    fun delete(path: String) {
        val dir = File(context.cacheDir, DIR).canonicalFile
        val f = File(path).canonicalFile
        if (f.parentFile == dir) f.delete()
    }

    fun isOwnRecording(path: String): Boolean {
        val dir = File(context.cacheDir, DIR).canonicalFile
        val f = File(path).canonicalFile
        return f.parentFile == dir && f.exists()
    }

    companion object {
        private const val DIR = "voice_notes"
        private const val DAY_MS = 24L * 60 * 60 * 1000
    }
}
