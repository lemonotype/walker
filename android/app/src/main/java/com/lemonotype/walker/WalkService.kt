package com.lemonotype.walker

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * Foreground service for an active session: keeps the process alive and puts
 * an ongoing notification with PAUSE/RESUME + END actions on the lock screen
 * (no authentication needed — Android notification actions just work).
 */
class WalkService : Service() {
    companion object {
        private const val CHANNEL = "walker.session"
        private const val NOTIF_ID = 1
        const val ACTION_TOGGLE = "com.lemonotype.walker.TOGGLE"
        const val ACTION_END = "com.lemonotype.walker.END"
        private var lastRefresh = 0L

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, WalkService::class.java))
        }
        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, WalkService::class.java))
        }
        fun refresh(ctx: Context) {
            val now = System.currentTimeMillis()
            if (now - lastRefresh < 5000) return
            lastRefresh = now
            ctx.startService(Intent(ctx, WalkService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val ch = NotificationChannel(CHANNEL, "Walking session",
            NotificationManager.IMPORTANCE_LOW)
        ch.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> Treadmill.togglePlayPause()
            ACTION_END -> { Treadmill.endSession(); return START_NOT_STICKY }
        }
        startForeground(NOTIF_ID, buildNotification())
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val s = Treadmill.elapsedS.value
        val time = if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60)
                   else "%02d:%02d".format(s / 60, s % 60)
        val text = "%s · %.2f KM · %d STEPS".format(
            time, Treadmill.distanceM.value / 1000, Treadmill.steps.value)

        fun action(label: String, act: String): Notification.Action {
            val pi = PendingIntent.getService(
                this, act.hashCode(),
                Intent(this, WalkService::class.java).setAction(act),
                PendingIntent.FLAG_IMMUTABLE)
            return Notification.Action.Builder(null, label, pi).build()
        }

        val openPi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE)

        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher)
            .setContentTitle(if (Treadmill.paused.value) "WALKER — PAUSED" else "WALKER")
            .setContentText(text)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(openPi)
            .addAction(action(if (Treadmill.paused.value) "RESUME" else "PAUSE", ACTION_TOGGLE))
            .addAction(action("END", ACTION_END))
            .build()
    }
}
