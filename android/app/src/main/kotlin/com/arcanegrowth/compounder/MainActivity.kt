package com.arcanegrowth.compounder

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private var restTimerChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            REST_TIMER_CHANNEL,
        )
        restTimerChannel = channel
        RestTimerService.onCancelled = {
            runOnUiThread {
                restTimerChannel?.invokeMethod("cancelled", null)
            }
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val endAtMs = (call.argument<Number>("endAtMs"))?.toLong()
                    if (endAtMs == null || endAtMs <= 0L) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(this, RestTimerService::class.java).apply {
                        action = RestTimerService.ACTION_START
                        putExtra(RestTimerService.EXTRA_END_AT_MS, endAtMs)
                    }
                    try {
                        ContextCompat.startForegroundService(this, intent)
                    } catch (_: Exception) {
                        // Starting a foreground service can be rejected if the
                        // app is already backgrounded; Dart still keeps wall-
                        // clock time when the user returns.
                    }
                    result.success(null)
                }

                "stop" -> {
                    val graceMs = (call.argument<Number>("graceMs"))?.toLong() ?: 0L
                    val active = RestTimerService.activeInstance
                    if (graceMs > 0L && active != null) {
                        active.scheduleStop(graceMs)
                    } else {
                        stopService(Intent(this, RestTimerService::class.java))
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        RestTimerService.onCancelled = null
        restTimerChannel?.setMethodCallHandler(null)
        restTimerChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        private const val REST_TIMER_CHANNEL = "com.arcanegrowth.compounder/rest_timer"
    }
}
