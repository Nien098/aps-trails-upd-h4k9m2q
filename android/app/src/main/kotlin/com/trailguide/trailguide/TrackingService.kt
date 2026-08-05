package com.trailguide.trailguide

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

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
        private const val TAG = "TrackingService"
        const val EXTRA_PAUSED = "paused"
    }

    override fun onCreate() {
        super.onCreate()
        try {
            val mgr = getSystemService(NotificationManager::class.java)
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                mgr.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Trail recording", NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        } catch (e: Exception) {
            // Same reasoning as onStartCommand: system-invoked, no MethodChannel
            // safety net, so an uncaught exception here is a real process crash.
            Log.e(TAG, "onCreate failed", e)
        }
    }

    // This method is invoked directly by Android (ActivityManagerService), not
    // through the trailguide/native MethodChannel — Flutter's own try/catch
    // around channel calls (which is why every NativeBridge call is silently
    // swallow-on-failure) does NOT cover this method. Anything thrown here
    // uncaught is a true, whole-process crash, e.g. via a START_STICKY
    // restart with no Activity/UI present and location permission revoked or
    // auto-revoked since the walk began. Stopping just this service instead
    // is a far smaller failure than taking down the app the walker is
    // actively relying on.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return try {
            val paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) ?: false
            val notification = buildNotification(paused)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                if (!hasLocationPermission()) {
                    // Manifest-declared as foregroundServiceType="location" — starting
                    // without the permission it needs would throw, and there's nothing
                    // useful to track without it anyway.
                    Log.w(TAG, "No location permission; stopping instead of starting foreground")
                    stopSelf()
                    return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
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

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED

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
