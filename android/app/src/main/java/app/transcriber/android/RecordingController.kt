package app.transcriber.android

/**
 * Pure, Android-free state machine for the recording lifecycle.
 *
 * This class contains **no Android imports** so it is fully unit-testable on the
 * JVM. [RecordingService] owns an instance of it and translates the [Action]s it
 * emits into real side effects (wake lock, audio focus, capture/engine control,
 * notification updates). Keeping the decision logic here means the service stays
 * a thin, hard-to-test shell while every interesting transition is covered by
 * fast JVM tests.
 *
 * ### States
 * - [RecordingState.Idle] — nothing is recording; no resources are held.
 * - [RecordingState.Recording] — capture is active and resources are held.
 * - [RecordingState.Paused] — capture is suspended (typically by audio-focus
 *   loss) but the service stays in the foreground holding resources, ready to
 *   resume.
 *
 * ### Events
 * Transitions are driven by [RecordingEvent]s. The machine is deliberately
 * forgiving: redundant events (e.g. [RecordingEvent.Start] while already
 * recording) are idempotent no-ops rather than errors.
 *
 * The controller is **not** thread-safe; the service confines all calls to a
 * single thread (the main looper).
 */
class RecordingController {

    /** The current lifecycle state. Starts as [RecordingState.Idle]. */
    var state: RecordingState = RecordingState.Idle
        private set

    /**
     * Folds [event] into the machine, mutating [state] and returning the ordered
     * list of side effects the caller must perform. The list is empty for no-op
     * transitions. Actions are returned in the order they should be executed.
     */
    fun dispatch(event: RecordingEvent): List<Action> = when (event) {
        RecordingEvent.Start -> onStart()
        RecordingEvent.Stop -> onStop()
        RecordingEvent.FocusLost -> onFocusLost()
        RecordingEvent.FocusLostTransient -> onFocusLostTransient()
        RecordingEvent.FocusGained -> onFocusGained()
        RecordingEvent.TaskRemoved -> onTaskRemoved()
    }

    /**
     * Start recording. From [RecordingState.Idle] this acquires the wake lock and
     * starts capture. While already [RecordingState.Recording] it is a no-op
     * (idempotent). From [RecordingState.Paused] it forces a resume of capture.
     */
    private fun onStart(): List<Action> = when (state) {
        RecordingState.Idle -> {
            state = RecordingState.Recording
            listOf(Action.AcquireWakeLock, Action.StartCapture)
        }
        RecordingState.Recording -> emptyList()
        RecordingState.Paused -> {
            state = RecordingState.Recording
            listOf(Action.ResumeCapture)
        }
    }

    /**
     * Stop recording from any active state. Stops capture and releases the wake
     * lock, returning to [RecordingState.Idle]. A no-op when already idle.
     */
    private fun onStop(): List<Action> = when (state) {
        RecordingState.Idle -> emptyList()
        RecordingState.Recording, RecordingState.Paused -> {
            state = RecordingState.Idle
            listOf(Action.StopCapture, Action.ReleaseWakeLock)
        }
    }

    /**
     * Permanent audio-focus loss (e.g. another app took the mic for good). Treated
     * like a transient loss for capture purposes — we pause rather than tear down,
     * so the user can resume from the notification or when focus returns.
     */
    private fun onFocusLost(): List<Action> = pause()

    /**
     * Transient audio-focus loss (e.g. an incoming phone call). Pauses capture but
     * keeps the service foregrounded and resources held, ready to resume on
     * [RecordingEvent.FocusGained].
     */
    private fun onFocusLostTransient(): List<Action> = pause()

    private fun pause(): List<Action> = when (state) {
        RecordingState.Recording -> {
            state = RecordingState.Paused
            listOf(Action.PauseCapture)
        }
        // Already paused or idle: nothing to pause.
        RecordingState.Paused, RecordingState.Idle -> emptyList()
    }

    /**
     * Audio focus regained. Resumes capture only if we were [RecordingState.Paused]
     * by a prior focus loss; ignored otherwise (a spurious gain while recording or
     * idle is harmless).
     */
    private fun onFocusGained(): List<Action> = when (state) {
        RecordingState.Paused -> {
            state = RecordingState.Recording
            listOf(Action.ResumeCapture)
        }
        RecordingState.Recording, RecordingState.Idle -> emptyList()
    }

    /**
     * The user swiped the app away from recents. We keep recording (the service is
     * [android.app.Service.START_STICKY]); no state change and no actions. Exists
     * as an explicit event so the service has a single funnel and tests document
     * the "swipe does not stop recording" contract.
     */
    private fun onTaskRemoved(): List<Action> = emptyList()
}

/** The three lifecycle states of [RecordingController]. */
enum class RecordingState {
    /** Not recording; no resources held. */
    Idle,

    /** Actively capturing audio; wake lock and audio focus held. */
    Recording,

    /** Capture suspended (e.g. by an incoming call) but resources retained. */
    Paused,
}

/** Inputs that drive [RecordingController] transitions. */
sealed interface RecordingEvent {
    /** User (or sticky restart) asked to begin recording. */
    data object Start : RecordingEvent

    /** User asked to stop recording entirely. */
    data object Stop : RecordingEvent

    /** Permanent audio-focus loss. */
    data object FocusLost : RecordingEvent

    /** Transient audio-focus loss, e.g. an incoming call. */
    data object FocusLostTransient : RecordingEvent

    /** Audio focus returned. */
    data object FocusGained : RecordingEvent

    /** App swiped from recents. */
    data object TaskRemoved : RecordingEvent
}

/**
 * Side-effect descriptors emitted by [RecordingController]. The controller never
 * performs effects itself; the service interprets these against real Android APIs
 * and the app-supplied [RecordingService.RecordingCallbacks].
 */
sealed interface Action {
    /** Acquire the partial wake lock. */
    data object AcquireWakeLock : Action

    /** Release the partial wake lock. */
    data object ReleaseWakeLock : Action

    /** Begin audio capture / engine session. */
    data object StartCapture : Action

    /** Stop audio capture / engine session. */
    data object StopCapture : Action

    /** Suspend capture without tearing down the session. */
    data object PauseCapture : Action

    /** Resume previously paused capture. */
    data object ResumeCapture : Action
}
