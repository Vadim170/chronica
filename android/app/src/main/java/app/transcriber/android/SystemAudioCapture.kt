package app.transcriber.android

import android.annotation.SuppressLint
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import kotlin.concurrent.thread

/**
 * Captures *system (loopback) audio* — i.e. the audio other apps play back — as
 * mono PCM16 on a dedicated background thread and forwards each frame to a sink
 * (typically a future `EngineBridge.pushRemoteFrame`, which targets the core's
 * [EngineBridge.REMOTE_CHANNEL]).
 *
 * This is the system-audio counterpart of [AudioCapture]: the sink signature is
 * identical — `(pcm: ShortArray, sampleRate: Int) -> Unit`, invoked off the main
 * thread for every captured frame — so the view-model can wire it the same way.
 *
 * The capture is built on [AudioPlaybackCaptureConfiguration] (API 29+, Android
 * Q), which requires a live [MediaProjection] token obtained from the user via
 * [android.media.projection.MediaProjectionManager.createScreenCaptureIntent].
 * That token is owned and kept alive by [MediaProjectionService]; this class is
 * a pure capture engine and does not manage projection lifecycle, notifications
 * or consent.
 *
 * ## What is and is not captured (IMPORTANT)
 * Playback capture only sees audio from apps that **allow** it. An app opts out
 * by declaring `android:allowAudioPlaybackCapture="false"` in its manifest, or
 * by calling [android.media.AudioManager.setAllowedCapturePolicy] /
 * `AudioAttributes.Builder.setAllowedCapturePolicy(...)` with a restrictive
 * policy. In addition, Android **blocks at the system level**:
 *  - audio of calls (telephony / VoIP routed through the voice-call usages), and
 *  - DRM-protected content (e.g. some streaming video/music).
 *
 * Concretely: this captures **media / screen audio**, not "the other party in a
 * phone call". A phone or VoIP call's remote participant is *not* capturable via
 * this API. This must be surfaced in the README and the UI so users do not
 * expect call recording.
 *
 * Only the playback-capturable usages are requested:
 * [AudioAttributes.USAGE_MEDIA], [AudioAttributes.USAGE_GAME] and
 * [AudioAttributes.USAGE_UNKNOWN] (see [CAPTURED_USAGES]). Communication/voice
 * usages are intentionally omitted because the platform never grants them to
 * playback capture.
 *
 * @param mediaProjection a started, not-yet-stopped projection token. The caller
 *   (the service) retains ownership and is responsible for stopping it.
 * @param sink invoked off the main thread for every captured frame, with the
 *   samples and the sample rate they were captured at ([SAMPLE_RATE]).
 */
@RequiresApi(Build.VERSION_CODES.Q)
class SystemAudioCapture(
    private val mediaProjection: MediaProjection,
    private val sink: (pcm: ShortArray, sampleRate: Int) -> Unit,
) {
    @Volatile
    private var running = false
    private var worker: Thread? = null
    private var record: AudioRecord? = null

    /** True between a successful [start] and [stop]. */
    val isRunning: Boolean get() = running

    /**
     * Starts loopback capture on a background thread. Idempotent: a second call
     * while running is ignored.
     *
     * @return true if capture started (or was already running), false if the
     *   [AudioRecord] could not be initialised (e.g. invalid projection, the
     *   buffer size could not be computed, or the device denied the config).
     */
    @SuppressLint("MissingPermission") // The MediaProjection grant authorises playback capture; RECORD_AUDIO is also held for the mic path.
    fun start(): Boolean {
        if (running) return true

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            Log.e(TAG, "getMinBufferSize returned $minBuf")
            return false
        }
        // Generous ring (4x min, at least ~100ms) to tolerate scheduling jitter.
        val bufBytes = maxOf(minBuf * 4, SAMPLE_RATE / 10 * BYTES_PER_SAMPLE)

        val config = buildCaptureConfig(mediaProjection)
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()

        val rec = try {
            AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufBytes)
                .setAudioPlaybackCaptureConfig(config)
                .build()
        } catch (e: UnsupportedOperationException) {
            // Thrown when the device/config cannot satisfy playback capture.
            Log.e(TAG, "AudioRecord.Builder failed for playback capture", e)
            return false
        } catch (e: IllegalStateException) {
            Log.e(TAG, "AudioRecord.Builder failed for playback capture", e)
            return false
        }

        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord not initialised (state=${rec.state})")
            rec.release()
            return false
        }

        record = rec
        running = true
        rec.startRecording()

        worker = thread(name = "system-audio-capture", isDaemon = true) {
            // ~100ms frames keep latency low while bounding JNI call overhead.
            val frame = ShortArray(SAMPLE_RATE / 10)
            while (running) {
                val n = rec.read(frame, 0, frame.size)
                if (n > 0) {
                    val chunk = if (n == frame.size) frame.copyOf() else frame.copyOf(n)
                    runCatching { sink(chunk, SAMPLE_RATE) }
                        .onFailure { Log.w(TAG, "sink threw", it) }
                } else if (n < 0) {
                    Log.e(TAG, "AudioRecord.read error $n")
                    break
                }
            }
        }
        return true
    }

    /** Stops capture and releases the recorder. Idempotent. Does not stop the projection. */
    fun stop() {
        running = false
        worker?.join(500)
        worker = null
        record?.let {
            runCatching { it.stop() }
            it.release()
        }
        record = null
    }

    companion object {
        private const val TAG = "SystemAudioCapture"

        /**
         * Whether system-audio (loopback) capture is available on this device.
         * [AudioPlaybackCaptureConfiguration] requires API 29 (Android Q).
         */
        val SUPPORTED: Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        /** Capture rate. 16 kHz is the ASR-native rate; the core resamples anyway. */
        const val SAMPLE_RATE = 16_000
        private const val BYTES_PER_SAMPLE = 2

        /**
         * The [AudioAttributes] usages requested for playback capture, in the
         * order they are added to the configuration.
         *
         * Only these usages are ever granted to playback capture by the
         * platform: general media, games, and content with an unspecified usage.
         * Communication/voice-call usages are deliberately excluded because the
         * platform refuses them (see the class KDoc caveat).
         */
        val CAPTURED_USAGES: IntArray = intArrayOf(
            AudioAttributes.USAGE_MEDIA,
            AudioAttributes.USAGE_GAME,
            AudioAttributes.USAGE_UNKNOWN,
        )

        /**
         * Builds the [AudioPlaybackCaptureConfiguration] for [projection],
         * adding every usage in [CAPTURED_USAGES].
         *
         * Extracted so the usage-selection logic is exercised by a JVM unit test
         * without a live projection ([CAPTURED_USAGES]).
         */
        @RequiresApi(Build.VERSION_CODES.Q)
        fun buildCaptureConfig(projection: MediaProjection): AudioPlaybackCaptureConfiguration {
            val builder = AudioPlaybackCaptureConfiguration.Builder(projection)
            for (usage in CAPTURED_USAGES) {
                builder.addMatchingUsage(usage)
            }
            return builder.build()
        }
    }
}
