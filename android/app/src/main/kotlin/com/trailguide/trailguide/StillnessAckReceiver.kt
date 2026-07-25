package com.trailguide.trailguide

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the "I'm OK" action on the stillness-nudge notification (see
 * MainActivity.showNudgeNotification) — lets the walker silence a nudge from
 * the notification shade without opening the app, the same way snoozing an
 * alarm doesn't require unlocking the phone. Reaches into the already-running
 * Flutter engine (cached by MainActivity) to invoke the same acknowledge()
 * path the in-app "I'm OK" button uses.
 */
class StillnessAckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        NotificationManagerCompat.from(context).cancel(MainActivity.NUDGE_NOTIF_ID)
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_CACHE_ID)
        if (engine == null) {
            // The app process (and with it the GPS/TTS/watchdog it's meant to
            // keep alive) isn't running — nothing left to acknowledge.
            Log.w("TGNative", "stillness ack: no cached engine")
            return
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "trailguide/native")
            .invokeMethod("acknowledgeStillness", null)
    }
}
