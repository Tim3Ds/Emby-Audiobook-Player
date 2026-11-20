package net.kellydev.audiobooks

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
        // A widget must never crash the host app: any failure here
        // just leaves the previous widget rendering in place.
        try {
            updateWidgetInner(context, manager, id)
        } catch (e: Exception) {
            // Swallow: playback matters, the widget is decoration.
        }
    }

    private fun updateWidgetInner(context: Context, manager: AppWidgetManager, id: Int) {
        val prefs = context.getSharedPreferences(
            "HomeWidgetPreferences", Context.MODE_PRIVATE
        )
        val title = prefs.getString("title", null) ?: "Emby Audiobook Player"
        val artist = prefs.getString("artist", null) ?: ""
        val playing = prefs.getBoolean("playing", false)
        val coverPath = prefs.getString("coverPath", null)

        val views = RemoteViews(context.packageName, R.layout.book_widget)
        views.setTextViewText(R.id.widget_title, title)
        views.setTextViewText(R.id.widget_artist, artist)
        views.setImageViewResource(
            R.id.widget_play,
            if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
        )
        val cover = coverPath?.let { decodeCover(it) }
        if (cover != null) {
            views.setImageViewBitmap(R.id.widget_cover, cover)
        } else {
            views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
        }

        // Play always goes through the app: it toggles when a
        // book is loaded, and continues the most recent book when
        // nothing is. (The previous build branched on whether the
        // audio service was running - that detection crashed the
        // app whenever playback updated the widget.)
        views.setOnClickPendingIntent(
            R.id.widget_play,
            HomeWidgetLaunchIntent.getActivity(
                context,
                MainActivity::class.java,
                Uri.parse("embyplayer://continue")
            )
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

    /// Decode the cover scaled down: a full-size bitmap can blow
    /// the RemoteViews transaction limit and the update silently
    /// never lands.
    private fun decodeCover(path: String): android.graphics.Bitmap? {
        val bounds = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (bounds.outWidth / sample > 256 ||
            bounds.outHeight / sample > 256
        ) {
            sample *= 2
        }
        return BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample }
        )
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
