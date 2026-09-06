package app.transcriber.android

import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Connects the [EngineBridge], the microphone [AudioCapture], and the foreground
 * [RecordingService] to the Compose UI.
 *
 * ### Who owns the recording lifecycle
 * The [RecordingService] is the source of truth for *when* capture runs: it holds
 * the wake lock, manages audio focus (pausing on an incoming call and resuming
 * after), and survives swipe-away. This view-model binds to the service and
 * supplies [RecordingService.RecordingCallbacks] so the service drives
 * `engine`/`capture` start/stop/pause/resume. The UI therefore only *requests*
 * start/stop via the service; it never starts capture directly (which would
 * double-start it).
 *
 * Heavy native calls (`loadModel`, `start`) run off the main thread.
 */
class MainViewModel(app: Application) : AndroidViewModel(app) {

    private val engine = EngineBridge(app)
    private val capture = AudioCapture { pcm, rate -> engine.pushMicFrame(pcm, rate) }

    /** UI state stream rendered by the screen. */
    val state: StateFlow<EngineState> = engine.state

    /** Linked Rust core version, for display. */
    val coreVersion: String get() = engine.coreVersion

    private var bound = false

    /** Capture hooks the service invokes on its lifecycle decisions (main thread). */
    private val recordingCallbacks = object : RecordingService.RecordingCallbacks {
        override fun onStart() {
            viewModelScope.launch(Dispatchers.IO) {
                runCatching {
                    engine.start()
                    capture.start()
                }
            }
        }

        override fun onStop() {
            viewModelScope.launch(Dispatchers.IO) {
                capture.stop()
                engine.stop()
            }
        }

        // Pause keeps the engine session alive (so partial intervals survive a
        // call) but stops feeding mic frames; resume re-opens the mic.
        override fun onPause() {
            capture.stop()
        }

        override fun onResume() {
            runCatching { capture.start() }
        }
    }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            (binder as? RecordingService.LocalBinder)?.service?.setCallbacks(recordingCallbacks)
        }

        override fun onServiceDisconnected(name: ComponentName?) { /* keep callbacks; rebind reattaches */ }
    }

    /**
     * Requests recording. Starts the foreground service (which begins capture via
     * the callbacks) and binds so the callbacks are attached. Errors surface
     * through [EngineState.lastError].
     */
    fun startRecording() {
        val ctx = getApplication<Application>()
        RecordingService.start(ctx)
        if (!bound) {
            ctx.bindService(
                Intent(ctx, RecordingService::class.java),
                connection,
                Context.BIND_AUTO_CREATE,
            )
            bound = true
        }
    }

    /** Requests a stop. The service stops capture/engine via the callbacks and tears down. */
    fun stopRecording() {
        val ctx = getApplication<Application>()
        RecordingService.stop(ctx)
        unbind()
    }

    /**
     * Starts system-audio (loopback) capture using a MediaProjection consent
     * result obtained by [MainActivity]. The engine session must be running (or
     * is started lazily) so the "remote" channel is registered. Frames are pushed
     * via [EngineBridge.pushRemoteFrame].
     *
     * @param resultCode the Activity result code from the screen-capture dialog.
     * @param data the result [Intent] from the dialog.
     */
    fun startSystemAudio(resultCode: Int, data: Intent) {
        if (!SystemAudioCapture.SUPPORTED) return
        MediaProjectionService.frameSink = { pcm, rate -> engine.pushRemoteFrame(pcm, rate) }
        viewModelScope.launch(Dispatchers.IO) {
            // Ensure the engine (and thus the "remote" channel) is live before frames arrive.
            runCatching { engine.start() }
        }
        MediaProjectionService.start(getApplication(), resultCode, data)
    }

    /** Stops system-audio capture and clears the frame sink. */
    fun stopSystemAudio() {
        MediaProjectionService.stop(getApplication())
        MediaProjectionService.frameSink = null
    }

    /** Requests a download of the given model id (progress arrives via events). */
    fun downloadModel(id: String) {
        viewModelScope.launch(Dispatchers.IO) { engine.downloadModel(id) }
    }

    /** Re-reads the model catalog. */
    fun refreshModels() {
        viewModelScope.launch(Dispatchers.IO) { engine.refreshModels() }
    }

    private fun unbind() {
        if (bound) {
            runCatching { getApplication<Application>().unbindService(connection) }
            bound = false
        }
    }

    override fun onCleared() {
        unbind()
        capture.stop()
        MediaProjectionService.frameSink = null
        engine.shutdown()
        super.onCleared()
    }
}
