package net.kellydev.audiobooks

import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioService

/// Invisible trampoline for the widget's buttons.
///
/// Why this exists: the buttons used to broadcast media keys to
/// the audio plugin's MediaButtonReceiver, which then had to
/// start the playback service from a broadcast-receiver (i.e.
/// background) context. Modern Android forbids exactly that -
/// the start is rejected or races the foreground-service
/// deadline, which on device showed up as the app crashing,
/// ANR popups, and zombie app windows after widget presses.
///
/// This activity is Theme.NoDisplay: it never shows UI and
/// finishes inside onCreate. But while it runs, the app holds a
/// foreground (activity) context, from which starting the
/// service is always legal. It hands the key event straight to
/// the AudioService with an explicit intent - the same door the
/// system's own media-button dispatch uses, since the service's
/// onStartCommand feeds the intent to the media session.
class WidgetActionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val keyCode = when (intent?.data?.host) {
                "rew" -> KeyEvent.KEYCODE_MEDIA_REWIND
                "fwd" -> KeyEvent.KEYCODE_MEDIA_FAST_FORWARD
                else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            }
            val svc = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                component = ComponentName(
                    this@WidgetActionActivity,
                    AudioService::class.java
                )
                putExtra(
                    Intent.EXTRA_KEY_EVENT,
                    KeyEvent(KeyEvent.ACTION_DOWN, keyCode)
                )
            }
            startService(svc)
        } catch (e: Exception) {
            // A widget action must never crash the app.
        } finally {
            finish()
        }
    }
}
