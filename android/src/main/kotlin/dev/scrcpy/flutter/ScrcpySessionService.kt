package dev.scrcpy.flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/** Keeps active remote-device sessions eligible for network access while locked. */
internal class ScrcpySessionService : Service() {
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val count = intent?.getIntExtra(EXTRA_SESSION_COUNT, 0)?.coerceAtLeast(0) ?: 0
        startForeground(NOTIFICATION_ID, notification(count))
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "scrcpy device sessions",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Keeps active device connections running in the background"
                setShowBadge(false)
            },
        )
    }

    private fun notification(count: Int): Notification {
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("设备连接运行中")
            .setContentText(
                if (count == 0) "正在保持设备连接"
                else "正在保持 $count 个投屏会话",
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "scrcpy_flutter_sessions"
        private const val NOTIFICATION_ID = 0x534352
        private const val EXTRA_SESSION_COUNT = "sessionCount"

        fun update(context: Context, sessionCount: Int) {
            if (sessionCount < 0) {
                context.stopService(Intent(context, ScrcpySessionService::class.java))
                return
            }
            val intent = Intent(context, ScrcpySessionService::class.java)
                .putExtra(EXTRA_SESSION_COUNT, sessionCount)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
