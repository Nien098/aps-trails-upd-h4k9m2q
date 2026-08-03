package com.trailguide.trailguide

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the Pause/Resume action on the walk-tracking notification (see
 * TrackingService.buildNotification) — lets the walker pause or resume a
 * walk from the notification shade without opening the app, the same
 * reach-into-the-cached-engine pattern StillnessAckReceiver already uses for
 * "I'm OK". Only works while the app process is alive (backgrounded, not
 * killed) — same caveat as the stillness action; a real process kill needs
 * the separate crash-safe checkpoint/resume-on-relaunch path instead.
 */
class WalkControlReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_PAUSE_WALK = "com.trailguide.trailguide.ACTION_PAUSE_WALK"
        const val ACTION_RESUME_WALK = "com.trailguide.trailguide.ACTION_RESUME_WALK"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val method = when (intent.action) {
            ACTION_PAUSE_WALK -> "pauseWalk"
            ACTION_RESUME_WALK -> "resumeWalk"
            else -> return
        }
        val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE_CACHE_ID)
        if (engine == null) {
            Log.w("TGNative", "walk control ($method): no cached engine")
            return
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "trailguide/native")
            .invokeMethod(method, null)
    }
}
