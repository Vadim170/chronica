package app.transcriber.android

import uniffi.transcriber_core.CoreEvent
import uniffi.transcriber_core.IntervalRecord
import uniffi.transcriber_core.MetricsSnapshot
import uniffi.transcriber_core.ModelStatus
import uniffi.transcriber_core.SessionState

/**
 * Immutable snapshot of everything the UI renders. Produced purely by
 * [reduce] from a previous state plus one [CoreEvent], which keeps the
 * event-handling logic free of Android/native dependencies and unit-testable.
 *
 * @property session Coarse engine lifecycle state.
 * @property metrics Latest metrics snapshot pushed by the core (~1/s), or null.
 * @property transcript Most-recent committed intervals, newest first (capped).
 * @property models Latest known status of every model the core manages.
 * @property lastError Human-readable text of the most recent error event, if any.
 */
data class EngineState(
    val session: SessionState = SessionState.IDLE,
    val metrics: MetricsSnapshot? = null,
    val transcript: List<IntervalRecord> = emptyList(),
    val models: List<ModelStatus> = emptyList(),
    val lastError: String? = null,
) {
    /** True while the core is actively recording and transcribing. */
    val isRecording: Boolean get() = session == SessionState.RECORDING

    /** Real-time factor of the busiest source, or null when idle. <1.0 is faster-than-realtime. */
    val realtimeFactor: Float?
        get() = metrics?.sources?.maxByOrNull { it.lastRtf }?.lastRtf?.takeIf { it > 0f }

    /** Total words transcribed in the current session. */
    val totalWords: UInt get() = metrics?.totalWords ?: 0u

    companion object {
        /** How many recent intervals to retain for the transcript feed. */
        const val MAX_TRANSCRIPT = 50
    }
}

/**
 * Pure reducer: folds a single [CoreEvent] into the running [EngineState].
 *
 * This is the single source of truth for how engine events change the UI and
 * is deliberately side-effect free so it can be unit-tested without the native
 * library, an emulator, or a device.
 *
 * @param prev the current UI state.
 * @param event the event just received from the core.
 * @return the next UI state.
 */
fun reduce(prev: EngineState, event: CoreEvent): EngineState = when (event) {
    is CoreEvent.StateChanged -> prev.copy(session = event.state)

    is CoreEvent.Metrics -> {
        // Surface the core's own error text if it carries one, but never clear
        // an existing error just because a clean snapshot arrived.
        val err = event.snapshot.lastError.takeIf { it.isNotBlank() } ?: prev.lastError
        prev.copy(metrics = event.snapshot, lastError = err)
    }

    is CoreEvent.IntervalCommitted -> {
        // Newest first, de-duplicated by id, capped to keep memory bounded.
        val merged = (listOf(event.interval) + prev.transcript)
            .distinctBy { it.id }
            .take(EngineState.MAX_TRANSCRIPT)
        prev.copy(transcript = merged)
    }

    is CoreEvent.ModelProgress -> {
        val updated = prev.models.toMutableList()
        val idx = updated.indexOfFirst { it.id == event.status.id }
        if (idx >= 0) updated[idx] = event.status else updated.add(event.status)
        prev.copy(models = updated)
    }

    is CoreEvent.Error -> prev.copy(lastError = "${event.code}: ${event.message}")

    // Per-channel voice-activity pings drive nothing in this minimal UI.
    is CoreEvent.VoiceActivity -> prev
}
