package app.transcriber.android

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import kotlin.concurrent.thread

/**
 * Captures microphone audio as mono PCM16 on a dedicated background thread and
 * forwards each frame to a sink (typically [EngineBridge.pushMicFrame]).
 *
 * The capture rate is the device-preferred 16 kHz where supported; the core
 * resamples internally regardless, so the exact rate is reported alongside each
 * frame and never assumed downstream.
 *
 * The caller must hold the `RECORD_AUDIO` runtime permission before [start];
 * this class does not request it.
 *
 * @param sink invoked off the main thread for every captured frame, with the
 *   samples and the sample rate they were captured at.
 */
class AudioCapture(
    private val sink: (pcm: ShortArray, sampleRate: Int) -> Unit,
) {
    @Volatile
    private var running = false
    private var worker: Thread? = null
    private var record: AudioRecord? = null

    /** True between a successful [start] and [stop]. */
    val isRunning: Boolean get() = running

    /**
     * Starts capture on a background thread. Idempotent: a second call while
     * running is ignored.
     *
     * @return true if capture started (or was already running), false if the
     *   [AudioRecord] could not be initialised (e.g. mic unavailable).
     */
    @SuppressLint("MissingPermission") // Caller guarantees RECORD_AUDIO is granted.
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

        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufBytes,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "AudioRecord not initialised (state=${rec.state})")
            rec.release()
            return false
        }

        record = rec
        running = true
        rec.startRecording()

        worker = thread(name = "mic-capture", isDaemon = true) {
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

    /** Stops capture and releases the recorder. Idempotent. */
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
        private const val TAG = "AudioCapture"

        /** Capture rate. 16 kHz is the ASR-native rate; the core resamples anyway. */
        const val SAMPLE_RATE = 16_000
        private const val BYTES_PER_SAMPLE = 2
    }
}
