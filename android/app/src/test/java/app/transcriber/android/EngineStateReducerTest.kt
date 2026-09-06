package app.transcriber.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.transcriber_core.ChannelText
import uniffi.transcriber_core.CoreEvent
import uniffi.transcriber_core.ErrorCode
import uniffi.transcriber_core.IntervalRecord
import uniffi.transcriber_core.MetricsSnapshot
import uniffi.transcriber_core.ModelStatus
import uniffi.transcriber_core.SessionState
import uniffi.transcriber_core.SourceMetrics

/**
 * Behavioural tests for the pure [reduce] event folder. These run on the JVM
 * without the native library, an emulator, or a device — they exercise how UI
 * state evolves in response to core events, not implementation details.
 */
class EngineStateReducerTest {

    private fun interval(id: Long, text: String) = IntervalRecord(
        id = id,
        startAt = "2026-01-01T00:00:00Z",
        endAt = "2026-01-01T00:00:30Z",
        durationS = 30.0,
        channels = listOf(ChannelText(channelId = "mic", text = text, words = 1u, language = "en")),
    )

    private fun metrics(words: UInt, rtf: Float, error: String = "") = MetricsSnapshot(
        stateRunning = true,
        stateLoading = false,
        stateStopping = false,
        modelLoaded = true,
        modelName = "parakeet",
        startedAt = "",
        lastWriteAt = "",
        totalWords = words,
        totalIntervals = 0u,
        bgQueueDepth = 0u,
        bgQueueCapacity = 64u,
        currentIntervalElapsedS = 0f,
        currentIntervalStartAt = "",
        channelsSilent = false,
        sources = listOf(
            SourceMetrics(
                channelId = "mic", enabled = true, status = "ok", queueSize = 0u,
                droppedChunks = 0u, busy = false, lastRtf = rtf, lagEstimateS = 0f,
                words = words, lastText = "", lastLanguage = "en", speechSeconds = 0f,
            ),
        ),
        cpuPercent = 0f,
        memoryRssBytes = 0u,
        lastError = error,
    )

    @Test
    fun stateChanged_updates_session() {
        val out = reduce(EngineState(), CoreEvent.StateChanged(SessionState.RECORDING))
        assertEquals(SessionState.RECORDING, out.session)
        assertTrue(out.isRecording)
    }

    @Test
    fun intervalCommitted_prepends_newest_first() {
        var s = EngineState()
        s = reduce(s, CoreEvent.IntervalCommitted(interval(1, "first")))
        s = reduce(s, CoreEvent.IntervalCommitted(interval(2, "second")))
        assertEquals(listOf(2L, 1L), s.transcript.map { it.id })
    }

    @Test
    fun intervalCommitted_deduplicates_by_id() {
        var s = EngineState()
        s = reduce(s, CoreEvent.IntervalCommitted(interval(1, "a")))
        s = reduce(s, CoreEvent.IntervalCommitted(interval(1, "a-again")))
        assertEquals(1, s.transcript.size)
    }

    @Test
    fun transcript_is_capped() {
        var s = EngineState()
        for (i in 1..(EngineState.MAX_TRANSCRIPT + 10)) {
            s = reduce(s, CoreEvent.IntervalCommitted(interval(i.toLong(), "x")))
        }
        assertEquals(EngineState.MAX_TRANSCRIPT, s.transcript.size)
        // Newest retained, oldest dropped.
        assertEquals((EngineState.MAX_TRANSCRIPT + 10).toLong(), s.transcript.first().id)
    }

    @Test
    fun metrics_surface_words_and_rtf() {
        val s = reduce(EngineState(), CoreEvent.Metrics(metrics(words = 42u, rtf = 0.5f)))
        assertEquals(42u, s.totalWords)
        assertEquals(0.5f, s.realtimeFactor!!, 1e-6f)
    }

    @Test
    fun clean_metrics_do_not_clear_existing_error() {
        var s = reduce(EngineState(), CoreEvent.Error(ErrorCode.AUDIO, "boom"))
        assertTrue(s.lastError!!.contains("boom"))
        s = reduce(s, CoreEvent.Metrics(metrics(words = 1u, rtf = 0f, error = "")))
        assertTrue(s.lastError!!.contains("boom"))
    }

    @Test
    fun metrics_with_error_text_is_surfaced() {
        val s = reduce(EngineState(), CoreEvent.Metrics(metrics(words = 0u, rtf = 0f, error = "disk full")))
        assertEquals("disk full", s.lastError)
    }

    @Test
    fun modelProgress_upserts_by_id() {
        val m1 = ModelStatus(
            id = "p", label = "Parakeet", family = "parakeet", runtime = "sherpa",
            installed = false, downloadedBytes = 0u, totalBytes = 100u, progressPct = 10f,
            downloading = true, lastError = "",
        )
        var s = reduce(EngineState(), CoreEvent.ModelProgress(m1))
        assertEquals(1, s.models.size)
        assertEquals(10f, s.models[0].progressPct, 1e-6f)

        val m2 = m1.copy(progressPct = 80f)
        s = reduce(s, CoreEvent.ModelProgress(m2))
        assertEquals(1, s.models.size) // upsert, not append
        assertEquals(80f, s.models[0].progressPct, 1e-6f)
    }

    @Test
    fun error_event_formats_code_and_message() {
        val s = reduce(EngineState(), CoreEvent.Error(ErrorCode.MODEL_LOAD, "missing"))
        assertTrue(s.lastError!!.contains("missing"))
    }

    @Test
    fun voiceActivity_is_inert_in_minimal_ui() {
        val before = EngineState(session = SessionState.RECORDING)
        val after = reduce(before, CoreEvent.VoiceActivity("mic", "2026-01-01T00:00:00Z"))
        assertEquals(before, after)
    }

    @Test
    fun realtimeFactor_is_null_when_idle() {
        assertNull(EngineState().realtimeFactor)
        assertEquals(0u, EngineState().totalWords)
        assertFalse(EngineState().isRecording)
    }
}
