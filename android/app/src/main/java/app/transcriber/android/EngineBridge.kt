package app.transcriber.android

import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import uniffi.transcriber_core.Acceleration
import uniffi.transcriber_core.ApiConfig
import uniffi.transcriber_core.ChannelSpec
import uniffi.transcriber_core.CoreConfig
import uniffi.transcriber_core.CoreEvent
import uniffi.transcriber_core.CoreEventListener
import uniffi.transcriber_core.LanguageMode
import uniffi.transcriber_core.ModelSpec
import uniffi.transcriber_core.ModelStatus
import uniffi.transcriber_core.TranscriberCore
import uniffi.transcriber_core.VadConfig
import uniffi.transcriber_core.coreVersion
import java.io.File

/**
 * Android-side facade over the native [TranscriberCore]. It mirrors the role of
 * the Swift `Engine`: it builds a [CoreConfig], owns the native instance,
 * receives [CoreEvent]s on a background (native) thread, folds them into an
 * [EngineState] via the pure [reduce] function, and publishes that state as a
 * [StateFlow] for Compose to observe.
 *
 * The bridge does not capture audio itself — [AudioCapture] feeds PCM frames in
 * through [pushMicFrame]. The core owns resampling, VAD, interval cutting, ASR
 * and persistence.
 *
 * @param context any context; only the application context and `filesDir` are used.
 */
class EngineBridge(context: Context) {

    private val appContext = context.applicationContext

    private val _state = MutableStateFlow(EngineState())

    /** Observable UI state. Always read on the main thread by Compose. */
    val state: StateFlow<EngineState> = _state.asStateFlow()

    /** Version string of the linked Rust core, e.g. for the about/footer. */
    val coreVersion: String by lazy { coreVersion() }

    @Volatile
    private var core: TranscriberCore? = null

    /** Receives events from the native core (off the main thread) and reduces them. */
    private val listener = object : CoreEventListener {
        override fun onEvent(event: CoreEvent) {
            // StateFlow.update is thread-safe; reduce is pure. The native core
            // may call this from its own worker thread.
            _state.update { prev -> reduce(prev, event) }
        }
    }

    /**
     * Builds the production [CoreConfig] for this device.
     *
     * Defaults follow the product spec: Parakeet model, auto language, auto
     * acceleration, 30s min / 300s max intervals, 2000ms silence cut. Storage
     * lives in `filesDir`; models in `filesDir/models`. The HTTP API is off.
     *
     * @param storageDir directory for the SQLite store (defaults to `filesDir`).
     * @param modelsDir directory for model files (defaults to `filesDir/models`).
     */
    fun buildConfig(
        storageDir: File = appContext.filesDir,
        modelsDir: File = File(appContext.filesDir, "models"),
    ): CoreConfig {
        modelsDir.mkdirs()
        return CoreConfig(
            model = ModelSpec.Parakeet(DEFAULT_MODEL_ID),
            language = LanguageMode.Auto,
            acceleration = Acceleration.AUTO,
            minIntervalS = 30u,
            maxIntervalS = 300u,
            silenceCutMs = 2000u,
            vad = VadConfig(sileroThreshold = 0.5f, rmsFallback = 0.008f),
            nThreads = 4u,
            bgQueueSize = 64u,
            audioQueueSize = 2048u,
            storagePath = storageDir.absolutePath,
            modelsPath = modelsDir.absolutePath,
            api = ApiConfig(enabled = false, host = "127.0.0.1", port = 8765u, token = ""),
        )
    }

    /**
     * Lazily creates the native core (if needed) and returns it. The single
     * "mic" channel is registered on first creation. Safe to call repeatedly.
     */
    @Synchronized
    private fun ensureCore(): TranscriberCore {
        core?.let { return it }
        val created = TranscriberCore(buildConfig(), listener)
        created.registerChannel(ChannelSpec(id = MIC_CHANNEL, label = "Microphone"))
        // The system-audio (loopback) channel is always registered so frames can
        // flow as soon as the user grants a MediaProjection (see SystemAudioCapture).
        created.registerChannel(ChannelSpec(id = REMOTE_CHANNEL, label = "System audio"))
        // Seed the model list so the UI can show download status immediately.
        runCatching { refreshModels(created) }
        core = created
        return created
    }

    /**
     * Loads the configured model and starts a recording session. Audio capture
     * is the caller's responsibility (see [AudioCapture]); the core only starts
     * consuming pushed frames after this returns.
     *
     * @throws uniffi.transcriber_core.CoreException on config/model/backend errors.
     */
    fun start() {
        val c = ensureCore()
        c.loadModel()
        c.start()
    }

    /** Stops the active session. No-op if not running. */
    fun stop() {
        runCatching { core?.stop() }.onFailure { Log.w(TAG, "stop failed", it) }
    }

    /**
     * Pushes a PCM16 mono mic frame into the core. Sample rate is whatever the
     * device's [AudioCapture] used; the core resamples internally.
     *
     * @param pcm signed 16-bit samples.
     * @param sampleRate capture rate in Hz.
     */
    fun pushMicFrame(pcm: ShortArray, sampleRate: Int) {
        val c = core ?: return
        c.pushAudioFrame(MIC_CHANNEL, pcm.toList(), sampleRate.toUInt(), 1u)
    }

    /**
     * Pushes a PCM16 mono system-audio frame into the core's [REMOTE_CHANNEL].
     * Mirrors [pushMicFrame]; fed by [SystemAudioCapture] / [MediaProjectionService].
     *
     * @param pcm signed 16-bit samples.
     * @param sampleRate capture rate in Hz (the core resamples internally).
     */
    fun pushRemoteFrame(pcm: ShortArray, sampleRate: Int) {
        val c = core ?: return
        c.pushAudioFrame(REMOTE_CHANNEL, pcm.toList(), sampleRate.toUInt(), 1u)
    }

    /** Triggers a download of the given model id; progress arrives via events. */
    fun downloadModel(id: String) {
        runCatching { ensureCore().downloadModel(id) }
            .onFailure { Log.w(TAG, "downloadModel($id) failed", it) }
    }

    /** Re-reads the model catalog from the core and publishes it to the UI. */
    fun refreshModels() = core?.let { refreshModels(it) }

    private fun refreshModels(c: TranscriberCore) {
        val models: List<ModelStatus> = c.listModels()
        _state.update { it.copy(models = models) }
    }

    /** Releases the native core. The bridge can be re-used; the next [start] recreates it. */
    @Synchronized
    fun shutdown() {
        runCatching { core?.stop() }
        core?.close()
        core = null
    }

    companion object {
        private const val TAG = "EngineBridge"

        /** Logical id of the microphone channel registered with the core. */
        const val MIC_CHANNEL = "mic"

        /** Logical id reserved for system-audio capture (see [SystemAudioCapture]). */
        const val REMOTE_CHANNEL = "remote"

        /** Default production model: multilingual Parakeet (matches core default). */
        const val DEFAULT_MODEL_ID = "parakeet-tdt-0.6b-v3-int8"
    }
}
