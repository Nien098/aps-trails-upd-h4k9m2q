package com.trailguide.trailguide

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.PendingIntent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import android.telephony.SmsManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Captures a `.trail` file opened via "open with" / share, reads its contents,
 * and hands them to Flutter on request (polled on launch and on resume). Also
 * bridges the tracking foreground service, emergency SMS, and battery-
 * optimization checks the stillness safety feature needs.
 */
class MainActivity : FlutterActivity() {
    private val importChannel = "trailguide/import"
    private val nativeChannel = "trailguide/native"
    private var pending: String? = null
    private var smsCounter = 0

    companion object {
        /// Cache key so StillnessAckReceiver (a static BroadcastReceiver, no
        /// Activity reference) can reach this same running Dart engine to
        /// acknowledge a nudge tapped from the notification shade.
        const val ENGINE_CACHE_ID = "trailguide_main_engine"
        const val NUDGE_CHANNEL_ID = "stillness_nudge_channel"
        const val NUDGE_NOTIF_ID = 2001
        const val ACTION_ACK_STILLNESS = "com.trailguide.trailguide.ACTION_ACK_STILLNESS"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_CACHE_ID, flutterEngine)
        pending = readIntent(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, importChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "getPendingImport") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, nativeChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startTracking" -> {
                        val svc = Intent(this, TrackingService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(svc)
                        } else {
                            startService(svc)
                        }
                        result.success(null)
                    }
                    "stopTracking" -> {
                        stopService(Intent(this, TrackingService::class.java))
                        result.success(null)
                    }
                    "sendSms" -> sendSms(
                        call.argument<String>("phone") ?: "",
                        call.argument<String>("message") ?: "",
                        result,
                    )
                    "showNudgeNotification" -> {
                        showNudgeNotification(
                            call.argument<String>("title") ?: "Still there?",
                            call.argument<String>("text") ?: "",
                        )
                        result.success(null)
                    }
                    "cancelNudgeNotification" -> {
                        NotificationManagerCompat.from(this).cancel(NUDGE_NOTIF_ID)
                        result.success(null)
                    }
                    "installApk" -> {
                        try {
                            installApk(call.argument<String>("path") ?: "")
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e("TGNative", "installApk failed", e)
                            result.error("install_failed", e.message, null)
                        }
                    }
                    "canInstallPackages" -> {
                        val can = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true // gated only by the global "unknown sources" toggle pre-O
                        }
                        result.success(can)
                    }
                    "requestInstallPackagesPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                startActivity(
                                    Intent(
                                        AndroidSettings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                        Uri.parse("package:$packageName"),
                                    )
                                )
                            } catch (e: Exception) {
                                Log.e("TGNative", "install-permission request failed", e)
                            }
                        }
                        result.success(null)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            startActivity(
                                Intent(
                                    AndroidSettings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:$packageName"),
                                )
                            )
                        } catch (e: Exception) {
                            Log.e("TGNative", "battery optimization request failed", e)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Sends an SMS and reports back whether the carrier actually accepted it
     * (not just that we called the API) — via a one-shot broadcast receiver
     * tied to SmsManager's sent-status PendingIntent. A no-signal / no-SIM
     * failure resolves this to false so the Dart-side watchdog can retry.
     */
    private fun sendSms(phone: String, message: String, result: MethodChannel.Result) {
        if (phone.isBlank() || message.isBlank()) {
            result.success(false)
            return
        }
        val action = "com.trailguide.trailguide.SMS_SENT_${smsCounter++}"
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                try {
                    unregisterReceiver(this)
                } catch (_: Exception) {}
                result.success(resultCode == Activity.RESULT_OK)
            }
        }
        val filter = IntentFilter(action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        try {
            val flags =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE
                else 0
            val sentIntent = PendingIntent.getBroadcast(this, 0, Intent(action), flags)
            SmsManager.getDefault().sendTextMessage(phone, null, message, sentIntent, null)
        } catch (e: Exception) {
            Log.e("TGNative", "sendSms failed", e)
            try {
                unregisterReceiver(receiver)
            } catch (_: Exception) {}
            result.success(false)
        }
    }

    /**
     * Posts the actionable "Still there?" notification — ongoing (can't be
     * swiped away, must be actioned) with an "I'm OK" button, the same
     * pattern an alarm clock uses for its snooze/dismiss actions. Tapping
     * the action fires StillnessAckReceiver, which reaches back into this
     * same cached engine to acknowledge without opening the app; tapping the
     * body instead opens the app.
     */
    private fun showNudgeNotification(title: String, text: String) {
        val mgr = getSystemService(NotificationManager::class.java)
        if (mgr.getNotificationChannel(NUDGE_CHANNEL_ID) == null) {
            mgr.createNotificationChannel(
                NotificationChannel(
                    NUDGE_CHANNEL_ID, "Stillness safety alert", NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
        val flags =
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0) or
                PendingIntent.FLAG_UPDATE_CURRENT
        val ackPending = PendingIntent.getBroadcast(
            this, 0,
            Intent(this, StillnessAckReceiver::class.java).setAction(ACTION_ACK_STILLNESS),
            flags,
        )
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = openIntent?.let { PendingIntent.getActivity(this, 0, it, flags) }

        val notification = NotificationCompat.Builder(this, NUDGE_CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(true)
            .setContentIntent(openPending)
            .addAction(0, "I'm OK", ackPending)
            .build()
        NotificationManagerCompat.from(this).notify(NUDGE_NOTIF_ID, notification)
    }

    /**
     * Launches the system package installer on a downloaded update APK.
     * Always shows Android's own install-confirmation screen — a normal app
     * (no root, no device-owner/MDM) can never install silently.
     */
    private fun installApk(path: String) {
        if (path.isBlank()) throw IllegalArgumentException("empty path")
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("downloaded file missing: $path")
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val data = readIntent(intent)
        if (data != null) pending = data
    }

    private fun readIntent(intent: Intent?): String? {
        if (intent == null) return null
        val uri: Uri? = when (intent.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM)
            else -> null
        }
        // A shared file (content:// with a read grant, or file://).
        if (uri != null) {
            return try {
                contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
            } catch (e: Exception) {
                Log.e("TGImport", "read failed", e)
                null
            }
        }
        // Or a trail shared as plain text.
        return intent.getStringExtra(Intent.EXTRA_TEXT)
    }
}
