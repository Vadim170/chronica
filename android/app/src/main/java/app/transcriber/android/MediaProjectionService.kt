package app.transcriber.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service (`foregroundServiceType="mediaProjection"`) that owns the
 * [MediaProjection] token granted by the user and runs the [SystemAudioCapture]
 * loopback engine for as long as system-audio capture is active.
 *
 * It mirrors [RecordingService] for the microphone path, but carries the heavier
 * MediaProjection contract:
 *
 * ## startForeground / getMediaProjection ordering (IMPORTANT)
 * On Android 14 (API 34+) the platform **requires** that a service of type
 * `mediaProjection` calls [startForeground] **before** the projection is
 * actually used (i.e. before [MediaProjectionManager.getMediaProjection] is
 * resolved into a working projection / before capture starts). Calling
 * `getMediaProjection` first, or starting capture before going foreground,
 * throws a `SecurityException` on API 34+. We therefore, inside
 * [onStartCommand]:
 *   1. build the notification channel and call [startForeground] **first**, then
 *   2. resolve [MediaProjectionManager.getMediaProjection] from the consent
 *      `resultCode` + data [Intent], then
 *   3. register a [MediaProjection.Callback] (also required on API 34+) and
 *   4. start [SystemAudioCapture].
 *
 * ## What is captured (caveat)
 * Only audio from apps that allow playback capture is captured; calls and
 * DRM-protected content are blocked by Android. See [SystemAudioCapture] for the
 * full caveat — this captures "media/screen audio", not phone-call audio.
 *
 * ## Sink wiring
 * The captured frames currently go to a no-op sink set via [frameSink]. The
 * tech lead should point [frameSink] at `EngineBridge.pushRemoteFrame` (see the
 * report). The sink is a process-global hook because a started [Service] cannot
 * easily receive object references through its start [Intent]; the view-model
 * sets it before [start] and clears it after [stop].
 */
class MediaProjectionService : Service() {

    private var projection: MediaProjection? = null
    private var capture: SystemAudioCapture? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // The user revoked the projection (or the system stopped it).
            Log.i(TAG, "MediaProjection stopped by system/user")
            stopCaptureAndSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // (1) Must go foreground BEFORE touching the projection on API 34+.
        startForeground(NOTIFICATION_ID, buildNotification())

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.e(TAG, "Playback capture unsupported below API 29")
            stopSelf()
            return START_NOT_STICKY
        }

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, RESULT_CODE_INVALID)
            ?: RESULT_CODE_INVALID
        @Suppress("DEPRECATION")
        val data: Intent? = intent?.getParcelableExtra(EXTRA_DATA)
        if (resultCode == RESULT_CODE_INVALID || data == null) {
            Log.e(TAG, "Missing projection consent extras; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        // (2) Resolve the projection now that we are foreground.
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val proj = manager.getMediaProjection(resultCode, data)
        if (proj == null) {
            Log.e(TAG, "getMediaProjection returned null; stopping")
            stopSelf()
            return START_NOT_STICKY
        }
        projection = proj

        // (3) Registering a callback is mandatory on API 34+.
        proj.registerCallback(projectionCallback, null)

        // (4) Start the capture engine over the projection.
        val cap = SystemAudioCapture(proj) { pcm, rate -> frameSink?.invoke(pcm, rate) }
        if (!cap.start()) {
            Log.e(TAG, "SystemAudioCapture failed to start; stopping")
            stopCaptureAndSelf()
            return START_NOT_STICKY
        }
        capture = cap
        return START_STICKY
    }

    override fun onDestroy() {
        stopCaptureAndSelf(stopSelf = false)
        super.onDestroy()
    }

    private fun stopCaptureAndSelf(stopSelf: Boolean = true) {
        capture?.stop()
        capture = null
        projection?.let {
            runCatching { it.unregisterCallback(projectionCallback) }
            runCatching { it.stop() }
        }
        projection = null
        if (stopSelf) stopSelf()
    }

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "System audio capture",
                NotificationManager.IMPORTANCE_LOW,
            )
            mgr.createNotificationChannel(channel)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Transcriber")
            .setContentText("Capturing system audio")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val TAG = "MediaProjectionService"
        private const val CHANNEL_ID = "media_projection"
        private const val NOTIFICATION_ID = 2
        private const val RESULT_CODE_INVALID = 0

        private const val EXTRA_RESULT_CODE = "app.transcriber.android.extra.RESULT_CODE"
        private const val EXTRA_DATA = "app.transcriber.android.extra.DATA"

        /**
         * Sink for captured system-audio frames. Set by the view-model to
         * `EngineBridge::pushRemoteFrame` before [start], cleared after [stop].
         * It is invoked off the main thread, once per ~100 ms frame.
         */
        @Volatile
        var frameSink: ((pcm: ShortArray, sampleRate: Int) -> Unit)? = null

        /**
         * Starts the foreground media-projection service with the consent result
         * from the Activity's screen-capture launcher.
         *
         * @param resultCode the Activity result code from the consent dialog.
         * @param dataIntent the result [Intent] from the consent dialog.
         */
        fun start(context: Context, resultCode: Int, dataIntent: Intent) {
            val intent = Intent(context, MediaProjectionService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_DATA, dataIntent)
            }
            context.startForegroundService(intent)
        }

        /** Stops the foreground media-projection service and releases the projection. */
        fun stop(context: Context) {
            context.stopService(Intent(context, MediaProjectionService::class.java))
        }
    }
}
