package com.speedyservice.eight_speedy_service

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and the `com.speedyservice.customer/voice` channel used
 * to record and preview the voice note that describes the vehicle problem.
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var recorder: VoiceRecorder? = null
    private var player: VoicePlayer? = null
    private var pendingMic: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        recorder = VoiceRecorder(applicationContext) {
            runOnUiThread { ch.invokeMethod("onRecordLimit", null) }
        }
        player = VoicePlayer { event -> runOnUiThread { ch.invokeMethod("onPlayer", event) } }
        ch.setMethodCallHandler { call, result -> handle(call, result) }
    }

    override fun onPause() {
        // Never keep the microphone open in the background.
        if (recorder?.isRecording == true) {
            recorder?.cancel()
            channel?.invokeMethod("onRecordCancelled", null)
        }
        player?.pause()
        super.onPause()
    }

    override fun onDestroy() {
        recorder?.cancel()
        player?.dispose()
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val rec = recorder
        val p = player
        if (rec == null || p == null) {
            result.error("not_ready", "Voice recorder is not ready", null)
            return
        }
        when (call.method) {
            "hasMic" -> result.success(hasMic())
            "requestMic" -> requestMic(result)
            "openAppSettings" -> {
                try {
                    startActivity(
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName"),
                        ),
                    )
                } catch (_: Exception) {
                }
                result.success(null)
            }
            "startRecording" -> {
                if (!hasMic()) {
                    result.error("no_permission", "Microphone permission is required", null)
                    return
                }
                p.stop()
                try {
                    val max = (call.argument<Int>("maxMs") ?: 60_000).coerceIn(5_000, 120_000)
                    result.success(rec.start(max))
                } catch (e: Exception) {
                    result.error("record_failed", e.message ?: "Could not start recording", null)
                }
            }
            "stopRecording" -> result.success(rec.stop())
            "cancelRecording" -> {
                rec.cancel()
                result.success(null)
            }
            "amplitude" -> result.success(rec.amplitude())
            "deleteRecording" -> {
                (call.arguments as? String)?.let { rec.delete(it) }
                result.success(null)
            }
            "playFile" -> {
                val path = call.arguments as? String
                if (path == null || !rec.isOwnRecording(path)) {
                    result.error("bad_source", "Unknown recording", null)
                } else {
                    p.play(path)
                    result.success(null)
                }
            }
            "pauseAudio" -> {
                p.pause()
                result.success(null)
            }
            "resumeAudio" -> {
                p.resume()
                result.success(null)
            }
            "stopAudio" -> {
                p.stop()
                result.success(null)
            }
            "audioPosition" -> result.success(p.position())
            else -> result.notImplemented()
        }
    }

    private fun hasMic(): Boolean =
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMic(result: MethodChannel.Result) {
        if (hasMic()) {
            result.success("granted")
            return
        }
        if (pendingMic != null) {
            result.success("denied")
            return
        }
        pendingMic = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQ_MIC)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_MIC) return
        val r = pendingMic ?: return
        pendingMic = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        val status = when {
            granted -> "granted"
            // "Don't ask again" (or denied twice): only Settings can enable it.
            !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> "blocked"
            else -> "denied"
        }
        r.success(status)
    }

    companion object {
        private const val CHANNEL = "com.speedyservice.customer/voice"
        private const val REQ_MIC = 7311
    }
}
