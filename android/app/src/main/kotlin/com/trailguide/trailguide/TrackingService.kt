package com.trailguide.trailguide

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * A foreground service whose main job is to raise this app's process
 * priority so Android doesn't suspend or kill it when the screen locks or
 * the app is backgrounded mid-walk — it does no tracking work itself, the
 * existing Dart GPS stream/TTS/watchdog keep running in the same process
 * exactly as in the foreground. It also carries the Pause/Resume action
 * button for the walk (see WalkControlReceiver): whichever side changes the
 * pause state (in-app button or this notification) calls back into
 * MainActivity to re-post the notification with the other action showing,
 * so the two stay in sync.
 */
class TrackingService : Service() {
    companion object {
        private const val CHANNEL_ID = "tracking_channel"
        private const val NOTIF_ID = 1001
        const val EXTRA_PAUSED = "paused"
    }

    override fun onCreate() {
        super.onCreate()
        val mgr = getSystemService(NotificationManager::class.java)
        if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "Trail recording", NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
        val notification = buildNotification(paused)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIF_ID, notification)
        }
        return START_STICKY
    }

    private fun buildNotification(paused: Boolean): Notification {
        val flags =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0) or
                PendingIntent.FLAG_UPDATE_CURRENT
        val action = if (paused) WalkControlReceiver.ACTION_RESUME_WALK else WalkControlReceiver.ACTION_PAUSE_WALK
        val actionPending = PendingIntent.getBroadcast(
            this, 0,
            Intent(this, WalkControlReceiver::class.java).setAction(action),
            flags,
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = openIntent?.let { PendingIntent.getActivity(this, 0, it, flags) }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("APS Trails")
            .setContentText(
                if (paused) "Walk paused — tap Resume to continue"
                else "Recording your walk — safe to lock the screen"
            )
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openPending)
            .addAction(0, if (paused) "Resume" else "Pause", actionPending)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
