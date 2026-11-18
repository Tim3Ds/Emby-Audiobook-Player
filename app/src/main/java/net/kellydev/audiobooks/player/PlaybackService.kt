package net.kellydev.audiobooks.player

import android.content.ComponentName
import net.kellydev.audiobooks.CrashLog
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

/**
 * Background playback service. The player lives here (not in the UI) so
 * books keep playing with the screen off, driven by the system media
 * notification and lock-screen controls.
 *
 * Audio focus is handled by the player: with handleAudioFocus = true a
 * notification's transient focus request DUCKS the book briefly instead
 * of pausing/freezing it — the exact behaviour the Emby app gets wrong.
 */
class PlaybackService : MediaSessionService() {

    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        try {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                .build()
            val player = ExoPlayer.Builder(this)
                .setAudioAttributes(audioAttributes, /* handleAudioFocus = */ true)
                .setHandleAudioBecomingNoisy(true)
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .build()
            mediaSession = MediaSession.Builder(this, player).build()
        } catch (t: Throwable) {
            // A failure building the player must not kill the whole app
            // process — record it so the next launch shows the trace,
            // and leave the session null (playback unavailable).
            CrashLog.record(this, t)
            mediaSession = null
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? =
        mediaSession

    override fun onDestroy() {
        mediaSession?.run {
            player.release()
            release()
        }
        mediaSession = null
        super.onDestroy()
    }

    companion object {
        fun sessionToken(context: android.content.Context) =
            androidx.media3.session.SessionToken(
                context,
                ComponentName(context, PlaybackService::class.java),
            )
    }
}
