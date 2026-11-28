package com.arcanegrowth.compounder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Short-lived foreground service active only during a workout rest countdown.
 *
 * Keeping the process at foreground-service importance with a timeout-bounded
 * partial wake lock prevents Android's App Freezer and screen-off CPU sleep
 * from suspending Dart's rest timer or delaying the 5-4-3-2-1 countdown ticks
 * and "go" audio cue while the app is minimized.
 */
class RestTimerService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var inForeground = false
    private val stopRunnable = Runnable { stopNow() }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                handler.removeCallbacks(stopRunnable)
                val endAtMs = intent.getLongExtra(EXTRA_END_AT_MS, 0L)
                val remainingMs = (endAtMs - System.currentTimeMillis()).coerceAtLeast(0L)
                // Always satisfy Android's startForeground() contract before
                // deciding whether to stop immediately.
                promoteToForeground(endAtMs)
                if (remainingMs <= 0L) {
                    stopNow()
                    return START_NOT_STICKY
                }
                val holdMs = (remainingMs + SAFETY_TAIL_MS).coerceIn(SAFETY_TAIL_MS, MAX_HOLD_MS)
                acquireWakeLock(holdMs)
                handler.postDelayed(stopRunnable, holdMs)
            }

            ACTION_STOP -> {
                val graceMs = intent.getLongExtra(EXTRA_GRACE_MS, 0L).coerceIn(0L, MAX_GRACE_MS)
                if (!inForeground) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                handler.removeCallbacks(stopRunnable)
                if (graceMs <= 0L) {
                    stopNow()
                } else {
                    handler.postDelayed(stopRunnable, graceMs)
                }
            }

            ACTION_CANCEL -> {
                handler.removeCallbacks(stopRunnable)
                onCancelled?.invoke()
                stopNow()
            }

            else -> {
                stopNow()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(stopRunnable)
        releaseWakeLock()
        inForeground = false
        if (activeInstance === this) {
            activeInstance = null
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    fun scheduleStop(graceMs: Long) {
        handler.post {
            if (!inForeground) {
                stopSelf()
                return@post
            }
            handler.removeCallbacks(stopRunnable)
            val clamped = graceMs.coerceIn(0L, MAX_GRACE_MS)
            if (clamped <= 0L) {
                stopNow()
            } else {
                handler.postDelayed(stopRunnable, clamped)
            }
        }
    }

    private fun promoteToForeground(endAtMs: Long) {
        ensureChannel()
        val notification = buildNotification(endAtMs)
        val serviceType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, serviceType)
        inForeground = true
        activeInstance = this
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Rest timer",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Live countdown shown while a workout rest timer is running"
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(endAtMs: Long): Notification {
        val openIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val cancelIntent = Intent(this, RestTimerService::class.java).apply {
            action = ACTION_CANCEL
        }
        val cancelPending = PendingIntent.getService(
            this,
            1,
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Rest timer")
            .setContentText("Tap to return to workout")
            .setContentIntent(openPending)
            .addAction(0, "Cancel", cancelPending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .setWhen(endAtMs)
            .setShowWhen(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        val powerManager = getSystemService(PowerManager::class.java) ?: return
        val lock = wakeLock ?: powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            WAKE_LOCK_TAG,
        ).apply {
            setReferenceCounted(false)
            wakeLock = this
        }
        lock.acquire(timeoutMs)
    }

    private fun releaseWakeLock() {
        val lock = wakeLock ?: return
        if (lock.isHeld) {
            lock.release()
        }
    }

    private fun stopNow() {
        handler.removeCallbacks(stopRunnable)
        releaseWakeLock()
        if (inForeground) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            inForeground = false
        }
        if (activeInstance === this) {
            activeInstance = null
        }
        stopSelf()
    }

    companion object {
        const val CHANNEL_ID = "compounder_rest_timer"
        const val NOTIFICATION_ID = 900
        const val ACTION_START = "com.arcanegrowth.compounder.action.REST_START"
        const val ACTION_STOP = "com.arcanegrowth.compounder.action.REST_STOP"
        const val ACTION_CANCEL = "com.arcanegrowth.compounder.action.REST_CANCEL"
        const val EXTRA_END_AT_MS = "end_at_ms"
        const val EXTRA_GRACE_MS = "grace_ms"

        private const val WAKE_LOCK_TAG = "compounder:RestTimer"
        private const val SAFETY_TAIL_MS = 3_000L
        // Settings caps rest at 600 s; add a small ceiling for the go-tone tail.
        private const val MAX_HOLD_MS = 610_000L
        private const val MAX_GRACE_MS = 5_000L

        @Volatile
        var activeInstance: RestTimerService? = null

        @Volatile
        var onCancelled: (() -> Unit)? = null
    }
}
