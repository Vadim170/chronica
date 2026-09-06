package app.transcriber.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioural tests for the pure [RecordingController] state machine. They run on
 * the JVM with no Android runtime, asserting the observable contract — resulting
 * [RecordingState] and emitted [Action]s — rather than implementation details.
 */
class RecordingControllerTest {

    private val controller = RecordingController()

    @Test
    fun start_from_idle_acquires_wakelock_and_starts_capture() {
        val actions = controller.dispatch(RecordingEvent.Start)

        assertEquals(RecordingState.Recording, controller.state)
        assertEquals(listOf(Action.AcquireWakeLock, Action.StartCapture), actions)
    }

    @Test
    fun double_start_is_idempotent_no_op() {
        controller.dispatch(RecordingEvent.Start)
        val second = controller.dispatch(RecordingEvent.Start)

        assertEquals(RecordingState.Recording, controller.state)
        assertTrue("second Start must be a no-op", second.isEmpty())
    }

    @Test
    fun transient_focus_loss_while_recording_pauses_capture() {
        controller.dispatch(RecordingEvent.Start)
        val actions = controller.dispatch(RecordingEvent.FocusLostTransient)

        assertEquals(RecordingState.Paused, controller.state)
        assertEquals(listOf(Action.PauseCapture), actions)
    }

    @Test
    fun permanent_focus_loss_while_recording_pauses_capture() {
        controller.dispatch(RecordingEvent.Start)
        val actions = controller.dispatch(RecordingEvent.FocusLost)

        assertEquals(RecordingState.Paused, controller.state)
        assertEquals(listOf(Action.PauseCapture), actions)
    }

    @Test
    fun focus_gain_while_paused_resumes_capture() {
        controller.dispatch(RecordingEvent.Start)
        controller.dispatch(RecordingEvent.FocusLostTransient)
        val actions = controller.dispatch(RecordingEvent.FocusGained)

        assertEquals(RecordingState.Recording, controller.state)
        assertEquals(listOf(Action.ResumeCapture), actions)
    }

    @Test
    fun focus_gain_while_recording_is_no_op() {
        controller.dispatch(RecordingEvent.Start)
        val actions = controller.dispatch(RecordingEvent.FocusGained)

        assertEquals(RecordingState.Recording, controller.state)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun focus_gain_while_idle_is_no_op() {
        val actions = controller.dispatch(RecordingEvent.FocusGained)

        assertEquals(RecordingState.Idle, controller.state)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun stop_while_recording_stops_capture_and_releases_wakelock() {
        controller.dispatch(RecordingEvent.Start)
        val actions = controller.dispatch(RecordingEvent.Stop)

        assertEquals(RecordingState.Idle, controller.state)
        assertEquals(listOf(Action.StopCapture, Action.ReleaseWakeLock), actions)
    }

    @Test
    fun stop_while_paused_stops_capture_and_releases_wakelock() {
        controller.dispatch(RecordingEvent.Start)
        controller.dispatch(RecordingEvent.FocusLostTransient)
        val actions = controller.dispatch(RecordingEvent.Stop)

        assertEquals(RecordingState.Idle, controller.state)
        assertEquals(listOf(Action.StopCapture, Action.ReleaseWakeLock), actions)
    }

    @Test
    fun stop_while_idle_is_no_op() {
        val actions = controller.dispatch(RecordingEvent.Stop)

        assertEquals(RecordingState.Idle, controller.state)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun start_while_paused_resumes_capture() {
        controller.dispatch(RecordingEvent.Start)
        controller.dispatch(RecordingEvent.FocusLostTransient)
        val actions = controller.dispatch(RecordingEvent.Start)

        assertEquals(RecordingState.Recording, controller.state)
        assertEquals(listOf(Action.ResumeCapture), actions)
    }

    @Test
    fun transient_focus_loss_while_paused_is_no_op() {
        controller.dispatch(RecordingEvent.Start)
        controller.dispatch(RecordingEvent.FocusLostTransient)
        val actions = controller.dispatch(RecordingEvent.FocusLostTransient)

        assertEquals(RecordingState.Paused, controller.state)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun focus_loss_while_idle_is_no_op() {
        val actions = controller.dispatch(RecordingEvent.FocusLostTransient)

        assertEquals(RecordingState.Idle, controller.state)
        assertTrue(actions.isEmpty())
    }

    @Test
    fun task_removed_does_not_stop_recording() {
        controller.dispatch(RecordingEvent.Start)
        val actions = controller.dispatch(RecordingEvent.TaskRemoved)

        assertEquals(RecordingState.Recording, controller.state)
        assertTrue("swipe-away must not change state or emit actions", actions.isEmpty())
    }

    @Test
    fun full_call_interruption_cycle_recovers_to_recording() {
        // Start, interrupted by a call (transient loss), then call ends (gain).
        assertEquals(
            listOf(Action.AcquireWakeLock, Action.StartCapture),
            controller.dispatch(RecordingEvent.Start),
        )
        assertEquals(
            listOf(Action.PauseCapture),
            controller.dispatch(RecordingEvent.FocusLostTransient),
        )
        assertEquals(
            listOf(Action.ResumeCapture),
            controller.dispatch(RecordingEvent.FocusGained),
        )
        assertEquals(RecordingState.Recording, controller.state)
    }
}
