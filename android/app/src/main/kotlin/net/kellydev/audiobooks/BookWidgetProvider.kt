package net.kellydev.audiobooks

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews

/// Home-screen widget: current book's cover, title, and transport
/// (rewind / play-pause / fast-forward). Data is published by the
/// Dart side through the home_widget plugin's shared preferences.
/// The buttons route through WidgetActionActivity, which hands
/// media keys to the audio service from a foreground context -
/// broadcasting them crashed the app on modern Android.
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

        // Buttons act silently through the invisible trampoline
        // activity (see WidgetActionActivity for why the old
        // media-key broadcasts crashed the app). Only non-button
        // areas (cover, title) open the app.
        views.setOnClickPendingIntent(
            R.id.widget_play,
            widgetAction(context, "toggle", 1)
        )
        views.setOnClickPendingIntent(
            R.id.widget_fwd,
            widgetAction(context, "fwd", 2)
        )
        views.setOnClickPendingIntent(
            R.id.widget_rew,
            widgetAction(context, "rew", 3)
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

    private fun widgetAction(
        context: Context,
        action: String,
        requestCode: Int
    ): PendingIntent {
        val intent = Intent(context, WidgetActionActivity::class.java).apply {
            data = Uri.parse("embyplayer://$action")
        }
        return PendingIntent.getActivity(
            context, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
