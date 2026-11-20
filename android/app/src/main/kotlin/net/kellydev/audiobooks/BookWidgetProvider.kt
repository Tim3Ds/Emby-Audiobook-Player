package net.kellydev.audiobooks

import android.app.ActivityManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.view.KeyEvent
import android.widget.RemoteViews
import com.ryanheise.audioservice.MediaButtonReceiver
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/// Home-screen widget: current book's cover, title, and transport
/// (rewind / play-pause / fast-forward). Data is published by the
/// Dart side through the home_widget plugin's shared preferences;
/// the buttons send media key events to the audio service, so
/// they work with the app in the background and use the same
/// configured skip lengths as everything else.
class BookWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray
    ) {
        for (id in ids) updateWidget(context, manager, id)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle
    ) {
        updateWidget(context, manager, id)
    }

    private fun updateWidget(context: Context, manager: AppWidgetManager, id: Int) {
        val prefs = context.getSharedPreferences(
            "HomeWidgetPreferences", Context.MODE_PRIVATE
        )
        val title = prefs.getString("title", null) ?: "Emby Audiobook Player"
        val artist = prefs.getString("artist", null) ?: ""
        // Nothing can be playing while the audio service is dead,
        // whatever the last published state says.
        val serviceRunning = isAudioServiceRunning(context)
        val playing = serviceRunning && prefs.getBoolean("playing", false)
        val coverPath = prefs.getString("coverPath", null)

        val views = RemoteViews(context.packageName, R.layout.book_widget)
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_artist, artist)
        views.setImageViewResource(
            R.id.widget_play,
            if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
        )
        val cover = coverPath?.let { BitmapFactory.decodeFile(it) }
        if (cover != null) {
            views.setImageViewBitmap(R.id.widget_cover, cover)
        } else {
            views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
        }

        // Play: with a live service this is a plain media
        // play/pause. With no service (app swiped away), launch
        // the app with the continue URI instead - it reopens the
        // most recent book at its server-saved position and plays.
        views.setOnClickPendingIntent(
            R.id.widget_play,
            if (serviceRunning) {
                mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            } else {
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("embyplayer://continue")
                )
            }
        )
        views.setOnClickPendingIntent(
            R.id.widget_fwd,
            mediaButton(context, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
        )
        views.setOnClickPendingIntent(
            R.id.widget_rew,
            mediaButton(context, KeyEvent.KEYCODE_MEDIA_REWIND)
        )
        val launch = Intent(context, MainActivity::class.java)
        val launchPi = PendingIntent.getActivity(
            context, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        views.setOnClickPendingIntent(R.id.widget_cover, launchPi)
        views.setOnClickPendingIntent(R.id.widget_title, launchPi)

        manager.updateAppWidget(id, views)
    }

    private fun isAudioServiceRunning(context: Context): Boolean {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as ActivityManager
        @Suppress("DEPRECATION")
        return am.getRunningServices(100).any {
            it.service.className == "com.ryanheise.audioservice.AudioService"
        }
    }

    private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(context, MediaButtonReceiver::class.java)
            putExtra(
                Intent.EXTRA_KEY_EVENT,
                KeyEvent(KeyEvent.ACTION_DOWN, keyCode)
            )
        }
        return PendingIntent.getBroadcast(
            context, keyCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
