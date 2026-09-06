package app.transcriber.android

import android.media.AudioAttributes
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Behavioural tests for [SystemAudioCapture]'s pure usage-selection contract.
 *
 * These guard the *policy* decision — exactly which playback-capture usages we
 * request, and that we never request a communication/voice-call usage (which the
 * platform would reject and which would mislead users into thinking call audio
 * is captured). They run on the JVM with no Android runtime; the constants are
 * plain `int`s from `android.jar`.
 */
class SystemAudioCaptureTest {

    @Test
    fun requests_exactly_media_game_and_unknown_in_order() {
        assertArrayEquals_ordered(
            intArrayOf(
                AudioAttributes.USAGE_MEDIA,
                AudioAttributes.USAGE_GAME,
                AudioAttributes.USAGE_UNKNOWN,
            ),
            SystemAudioCapture.CAPTURED_USAGES,
        )
    }

    @Test
    fun never_requests_voice_communication_usage() {
        // Capturing call audio is impossible via playback capture and must not be
        // attempted — assert the policy excludes the comms usages explicitly.
        val captured = SystemAudioCapture.CAPTURED_USAGES.toSet()
        assertFalse(captured.contains(AudioAttributes.USAGE_VOICE_COMMUNICATION))
        assertFalse(captured.contains(AudioAttributes.USAGE_NOTIFICATION_RINGTONE))
    }

    @Test
    fun has_no_duplicate_usages() {
        val arr = SystemAudioCapture.CAPTURED_USAGES
        assertEquals(arr.size, arr.toSet().size)
    }

    private fun assertArrayEquals_ordered(expected: IntArray, actual: IntArray) {
        assertEquals("size", expected.size, actual.size)
        for (i in expected.indices) {
            assertTrue("index $i: expected ${expected[i]} got ${actual[i]}", expected[i] == actual[i])
        }
    }
}
