package app.transcriber.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log

/**
 * Production-grade foreground service that owns the **robustness** of a recording
 * session for `foregroundServiceType=microphone`. The actual audio capture and
 * native engine remain owned by [MainViewModel]/[EngineBridge]; this service only
 * decides *when* capture should run and holds the OS-level resources that keep it
 * alive and well-behaved:
 *
 * - a persistent ongoing notification with Start/Stop actions and a tap target
 *   that opens [MainActivity];
 * - a [PowerManager.PARTIAL_WAKE_LOCK] so the CPU keeps transcribing with the
 *   screen off;
 * - audio-focus management so an incoming call pauses recording and its end
 *   resumes it;
 * - [START_STICKY] + [onTaskRemoved] so a swipe-away or process death does not
 *   silently kill the session.
 *
 * ### Decoupling from capture
 * The service never touches [android.media.AudioRecord] or the engine directly.
 * Instead it exposes [RecordingCallbacks]; the app sets them via [LocalBinder]
 * (bind) or by calling [setCallbacks] on the static instance reference. All
 * lifecycle decisions are delegated to the pure [RecordingController] state
 * machine, whose [Action]s are translated into resource changes plus callback
 * invocations in [perform].
 *
 * ### Threading
 * The controller and all callback dispatch are confined to the main looper, so
 * neither needs to be thread-safe. Native work triggered by callbacks should be
 * offloaded by the app (as [MainViewModel] already does with `Dispatchers.IO`).
 */
class RecordingService : Service() {

    /**
     * App-supplied hooks the service calls when the [RecordingController] decides
     * capture must start/stop/pause/resume. All callbacks fire on the main thread;
     * keep them fast or offload heavy native calls. Every callback is optional.
     */
    interface RecordingCallbacks {
        /** Begin capture + engine session. */
        fun onStart() {}

        /** Stop capture + engine session. */
        fun onStop() {}

        /** Suspend capture (e.g. incoming call) without tearing down the session. */
        fun onPause() {}

        /** Resume capture after a prior pause. */
        fun onResume() {}
    }

    /** Binder exposing this service so the app can wire [RecordingCallbacks]. */
    inner class LocalBinder : android.os.Binder() {
        /** The bound service instance. */
        val service: RecordingService get() = this@RecordingService
    }

    private val binder = LocalBinder()
    private val controller = RecordingController()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var callbacks: RecordingCallbacks? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var hasAudioFocus = false

    private val audioManager: AudioManager by lazy {
        getSystemService(Context.AUDIO_SERVICE) as AudioManager
    }
    private val notificationManager: NotificationManager by lazy {
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    }

    /** Reflects audio-focus changes into controller events on the main thread. */
    private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
        mainHandler.post {
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS -> {
                    hasAudioFocus = false
                    perform(controller.dispatch(RecordingEvent.FocusLost))
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    hasAudioFocus = false
                    perform(controller.dispatch(RecordingEvent.FocusLostTransient))
                }
                AudioManager.AUDIOFOCUS_GAIN -> {
                    hasAudioFocus = true
                    perform(controller.dispatch(RecordingEvent.FocusGained))
                }
            }
            updateNotification()
        }
    }

    override fun onBind(intent: Intent?): IBinder = binder

    /**
     * Sets (or clears) the app-side capture hooks. If recording is already active
     * when callbacks are first attached, [RecordingCallbacks.onStart] is invoked so
     * a late binder (e.g. after a sticky restart) catches up to current state.
     */
    fun setCallbacks(cb: RecordingCallbacks?) {
        callbacks = cb
        if (cb != null && controller.state == RecordingState.Recording) {
            cb.onStart()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Promote to foreground immediately to satisfy the
        // startForegroundService -> startForeground contract on every entry.
        startForeground(NOTIFICATION_ID, buildNotification())

        when {
            intent?.action == ACTION_STOP -> {
                perform(controller.dispatch(RecordingEvent.Stop))
                teardownAndStop()
                return START_NOT_STICKY
            }
            // A null intent is the OS redelivering after a sticky restart: resume
            // recording. ACTION_START (or any other start) also begins recording.
            intent == null -> {
                Log.i(TAG, "Sticky restart with null intent: resuming recording")
                beginRecording()
            }
            else -> beginRecording()
        }
        updateNotification()
        return START_STICKY
    }

    private fun beginRecording() {
        requestAudioFocus()
        perform(controller.dispatch(RecordingEvent.Start))
    }

    /**
     * Translates controller [Action]s into real side effects. Wake-lock and focus
     * effects touch the OS; capture effects fan out to [callbacks]. Order is
     * preserved as emitted by the controller.
     */
    private fun perform(actions: List<Action>) {
        for (action in actions) {
            when (action) {
                Action.AcquireWakeLock -> acquireWakeLock()
                Action.ReleaseWakeLock -> releaseWakeLock()
                Action.StartCapture -> callbacks?.onStart()
                Action.StopCapture -> callbacks?.onStop()
                Action.PauseCapture -> callbacks?.onPause()
                Action.ResumeCapture -> callbacks?.onResume()
            }
        }
    }

    // ---- Wake lock ---------------------------------------------------------

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) runCatching { it.release() } }
        wakeLock = null
    }

    // ---- Audio focus -------------------------------------------------------

    private fun requestAudioFocus() {
        if (hasAudioFocus) return
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .setOnAudioFocusChangeListener(focusListener, mainHandler)
            .setWillPauseWhenDucked(true)
            .build()
        audioFocusRequest = request
        val result = audioManager.requestAudioFocus(request)
        hasAudioFocus = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        audioFocusRequest = null
        hasAudioFocus = false
    }

    // ---- Notification ------------------------------------------------------

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        ensureChannel()

        val contentIntent = PendingIntent.getActivity(
            this,
            REQ_CONTENT,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val paused = controller.state == RecordingState.Paused
        val text = when {
            controller.state == RecordingState.Idle -> "Idle"
            paused -> "Paused"
            else -> "Recording and transcribing"
        }

        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Transcriber")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(action(ACTION_START, "Start", REQ_START))
            .addAction(action(ACTION_STOP, "Stop", REQ_STOP))

        return builder.build()
    }

    private fun action(actionName: String, label: String, requestCode: Int): Notification.Action {
        val pi = PendingIntent.getService(
            this,
            requestCode,
            Intent(this, RecordingService::class.java).setAction(actionName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Action.Builder(null as android.graphics.drawable.Icon?, label, pi).build()
    }

    private fun updateNotification() {
        notificationManager.notify(NOTIFICATION_ID, buildNotification())
    }

    // ---- Lifecycle ---------------------------------------------------------

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swipe-away must NOT stop recording (START_STICKY contract).
        perform(controller.dispatch(RecordingEvent.TaskRemoved))
        super.onTaskRemoved(rootIntent)
    }

    private fun teardownAndStop() {
        releaseEverything()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun releaseEverything() {
        releaseWakeLock()
        abandonAudioFocus()
    }

    override fun onDestroy() {
        // Defensive: ensure capture is stopped and all OS resources are freed even
        // if we are destroyed without an ACTION_STOP (e.g. low-memory kill).
        if (controller.state != RecordingState.Idle) {
            perform(controller.dispatch(RecordingEvent.Stop))
        }
        releaseEverything()
        callbacks = null
        super.onDestroy()
    }

    companion object {
        private const val TAG = "RecordingService"

        private const val CHANNEL_ID = "recording"
        private const val CHANNEL_NAME = "Recording"
        private const val NOTIFICATION_ID = 1
        private const val WAKE_LOCK_TAG = "transcriber:recording"

        private const val REQ_CONTENT = 0
        private const val REQ_START = 1
        private const val REQ_STOP = 2

        /** Intent action: begin (or resume) recording. */
        const val ACTION_START = "app.transcriber.android.action.START"

        /** Intent action: stop recording and tear the service down. */
        const val ACTION_STOP = "app.transcriber.android.action.STOP"

        /** Starts the foreground recording service with an explicit start action. */
        fun start(context: Context) {
            val intent = Intent(context, RecordingService::class.java).setAction(ACTION_START)
            context.startForegroundService(intent)
        }

        /** Asks the service to stop recording and remove itself from the foreground. */
        fun stop(context: Context) {
            val intent = Intent(context, RecordingService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
