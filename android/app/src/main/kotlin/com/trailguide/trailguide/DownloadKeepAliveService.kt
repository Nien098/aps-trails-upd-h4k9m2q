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
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * A foreground service whose only job is to raise this app's process
 * priority so Android doesn't suspend/kill it mid-download when the app is
 * backgrounded or the screen locks — mirrors [TrackingService]'s reasoning
 * exactly, just for a region/update download instead of a walk. It does no
 * downloading itself; the existing Dart HttpClient stream in
 * RegionDownloader/Updater keeps running in the same process. Started right
 * before a download begins and stopped in that download's `finally` block,
 * so it never outlives the download it's covering.
 */
class DownloadKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "download_channel"
        private const val NOTIF_ID = 1002
        private const val TAG = "DownloadKeepAliveService"
        const val EXTRA_TEXT = "text"
    }

    override fun onCreate() {
        super.onCreate()
        try {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "onCreate failed", e)
        }
    }

    // Same reasoning as TrackingService.onStartCommand: this is invoked
    // directly by Android, not through the trailguide/native MethodChannel's
    // try/catch safety net — an uncaught exception here is a real process
    // crash, so stopping just this service on failure is far safer than
    // letting that propagate.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Downloading…"
            val notification = buildNotification(text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notification)
            }
            START_STICKY
        } catch (e: Exception) {
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
            START_NOT_STICKY
        }
    }

    private fun buildNotification(text: String): Notification {
        val flags =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0) or
                PendingIntent.FLAG_UPDATE_CURRENT
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = openIntent?.let { PendingIntent.getActivity(this, 0, it, flags) }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("APS Trails")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openPending)
            .build()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
