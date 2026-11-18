package net.kellydev.audiobooks.ui

import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaController
import coil.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import net.kellydev.audiobooks.data.EmbyApi
import net.kellydev.audiobooks.data.EmbyItem
import net.kellydev.audiobooks.data.SessionStore
import net.kellydev.audiobooks.player.BookSession

/** Prepare the player for a book and start it at the saved position. */
suspend fun startBook(
    api: EmbyApi,
    controller: MediaController,
    listItem: EmbyItem,
): BookSession {
    val details = runCatching { api.itemDetails(listItem.Id) }.getOrDefault(listItem)
    val info = api.playbackInfo(listItem.Id)
    val session = BookSession(details, info.MediaSources, info.PlaySessionId)

    val mediaItems = info.MediaSources.map { source ->
        MediaItem.Builder()
            .setMediaId(source.Id)
            .setUri(api.streamUrl(listItem.Id, source))
            .setMediaMetadata(
                MediaMetadata.Builder()
                    .setTitle(details.Name)
                    .setArtist(details.author)
                    .setArtworkUri(Uri.parse(api.imageUrl(listItem.Id)))
                    .build()
            )
            .build()
    }
    val startTicks = listItem.UserData?.PlaybackPositionTicks
        ?: details.UserData?.PlaybackPositionTicks ?: 0L
    val (trackIndex, offsetMs) = session.locate(EmbyApi.ticksToMs(startTicks))
    controller.setMediaItems(mediaItems, trackIndex, offsetMs)
    controller.prepare()
    controller.play()
    api.reportPlaying(listItem.Id, info.PlaySessionId, startTicks)
    return session
}

@Composable
fun PlayerScreen(
    api: EmbyApi,
    store: SessionStore,
    controller: MediaController,
    session: BookSession,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()

    var isPlaying by remember { mutableStateOf(controller.isPlaying) }
    var globalMs by remember { mutableLongStateOf(0L) }
    var trackIndex by remember { mutableStateOf(controller.currentMediaItemIndex) }
    var speed by remember { mutableStateOf(controller.playbackParameters.speed) }
    var skipFwd by remember { mutableStateOf(store.skipForwardSec) }
    var skipBack by remember { mutableStateOf(store.skipBackSec) }

    var scrubbing by remember { mutableStateOf(false) }
    var scrubMs by remember { mutableLongStateOf(0L) }

    // Poll the player, keep the on-screen position fresh, and report
    // progress to Emby every ~10s so the position stays synced.
    LaunchedEffect(controller, session) {
        var ticks = 0
        var wasPlaying = controller.isPlaying
        while (true) {
            isPlaying = controller.isPlaying
            trackIndex = controller.currentMediaItemIndex
            globalMs = session.globalMs(trackIndex, controller.currentPosition)
            speed = controller.playbackParameters.speed
            ticks++
            if (ticks >= 20) {
                ticks = 0
                api.reportProgress(
                    session.item.Id, session.playSessionId,
                    EmbyApi.msToTicks(globalMs), isPaused = !isPlaying,
                )
            }
            if (wasPlaying && !isPlaying) {
                api.reportProgress(
                    session.item.Id, session.playSessionId,
                    EmbyApi.msToTicks(globalMs), isPaused = true,
                )
            }
            wasPlaying = isPlaying
            delay(500)
        }
    }

    // Leaving the player tells Emby the session ended at this position.
    DisposableEffect(session) {
        onDispose {
            scope.launch {
                api.reportStopped(
                    session.item.Id, session.playSessionId,
                    EmbyApi.msToTicks(globalMs),
                )
            }
        }
    }

    fun seekGlobal(targetMs: Long) {
        val clamped = targetMs.coerceIn(0L, if (session.totalMs > 0) session.totalMs else Long.MAX_VALUE)
        val (idx, off) = session.locate(clamped)
        controller.seekTo(idx, off)
        globalMs = clamped
    }

    fun prevChapter() {
        val starts = session.chapters.map { session.chapterStartMs(it) }
        val current = session.currentChapterIndex(globalMs)
        if (current < 0) return
        val intoChapter = globalMs - starts[current]
        val target = if (intoChapter > 3_000L || current == 0) starts[current] else starts[current - 1]
        seekGlobal(target)
    }

    fun nextChapter() {
        val starts = session.chapters.map { session.chapterStartMs(it) }
        val next = starts.firstOrNull { it > globalMs + 500L }
        if (next != null) seekGlobal(next)
        else if (trackIndex < session.sources.size - 1) controller.seekTo(trackIndex + 1, 0L)
    }

    fun prevTrack() {
        if (controller.currentPosition > 3_000L || trackIndex == 0) {
            controller.seekTo(trackIndex, 0L)
        } else {
            controller.seekTo(trackIndex - 1, 0L)
        }
    }

    fun nextTrack() {
        if (trackIndex < session.sources.size - 1) controller.seekTo(trackIndex + 1, 0L)
    }

    val chapterIdx = session.currentChapterIndex(globalMs)
    val chapterName = session.chapters.getOrNull(chapterIdx)?.Name?.takeIf { it.isNotBlank() }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to library")
            }
            Text("Now Playing", style = MaterialTheme.typography.titleMedium)
        }

        Spacer(Modifier.height(8.dp))
        if (session.item.hasPrimaryImage) {
            AsyncImage(
                model = api.imageUrl(session.item.Id),
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(220.dp)
                    .clip(MaterialTheme.shapes.medium)
                    .align(Alignment.CenterHorizontally),
            )
            Spacer(Modifier.height(16.dp))
        }

        Text(session.item.Name, style = MaterialTheme.typography.headlineSmall)
        if (session.item.author.isNotBlank()) {
            Text(session.item.author, style = MaterialTheme.typography.bodyLarge)
        }
        Spacer(Modifier.height(4.dp))
        Text(
            buildString {
                if (session.sources.size > 1) append("Track ${trackIndex + 1} of ${session.sources.size}")
                if (chapterName != null) {
                    if (isNotEmpty()) append(" · ")
                    append(chapterName)
                    if (session.chapters.size > 1) append(" (${chapterIdx + 1}/${session.chapters.size})")
                }
            },
            style = MaterialTheme.typography.bodyMedium,
        )

        Spacer(Modifier.height(16.dp))
        val shownMs = if (scrubbing) scrubMs else globalMs
        if (session.totalMs > 0) {
            Slider(
                value = shownMs.toFloat(),
                onValueChange = { scrubbing = true; scrubMs = it.toLong() },
                onValueChangeFinished = { seekGlobal(scrubMs); scrubbing = false },
                valueRange = 0f..session.totalMs.toFloat(),
            )
            Row(Modifier.fillMaxWidth()) {
                Text(formatTime(shownMs), style = MaterialTheme.typography.bodySmall)
                Spacer(Modifier.weight(1f))
                Text(formatTime(session.totalMs), style = MaterialTheme.typography.bodySmall)
            }
        }

        Spacer(Modifier.height(8.dp))
        // Main transport: prev track | skip back | play/pause | skip fwd | next track
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = ::prevTrack, enabled = session.sources.size > 1) {
                Icon(Icons.Filled.SkipPrevious, contentDescription = "Previous track", modifier = Modifier.size(32.dp))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                IconButton(onClick = { seekGlobal(globalMs - skipBack * 1000L) }) {
                    Icon(Icons.Filled.Replay, contentDescription = "Skip back", modifier = Modifier.size(32.dp))
                }
                Text("-${skipBack}s", style = MaterialTheme.typography.labelSmall)
            }
            Button(
                onClick = { if (isPlaying) controller.pause() else controller.play() },
                modifier = Modifier.size(72.dp),
            ) {
                Icon(
                    if (isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (isPlaying) "Pause" else "Play",
                    modifier = Modifier.size(36.dp),
                )
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                IconButton(onClick = { seekGlobal(globalMs + skipFwd * 1000L) }) {
                    Icon(Icons.Filled.Forward30, contentDescription = "Skip forward", modifier = Modifier.size(32.dp))
                }
                Text("+${skipFwd}s", style = MaterialTheme.typography.labelSmall)
            }
            IconButton(onClick = ::nextTrack, enabled = session.sources.size > 1) {
                Icon(Icons.Filled.SkipNext, contentDescription = "Next track", modifier = Modifier.size(32.dp))
            }
        }

        // Chapter transport
        if (session.chapters.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                TextButton(onClick = ::prevChapter) { Text("‹  Prev chapter") }
                TextButton(onClick = ::nextChapter) { Text("Next chapter  ›") }
            }
        }

        Spacer(Modifier.height(16.dp))
        // Playback speed
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        ) {
            listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f).forEach { s ->
                FilterChip(
                    selected = speed == s,
                    onClick = { controller.setPlaybackSpeed(s); speed = s },
                    label = { Text("${s}×") },
                )
            }
        }

        Spacer(Modifier.height(12.dp))
        // Skip interval settings
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            TextButton(onClick = {
                skipBack = nextIn(skipBack, listOf(5, 10, 15, 30))
                store.skipBackSec = skipBack
            }) { Text("Skip back: ${skipBack}s") }
            TextButton(onClick = {
                skipFwd = nextIn(skipFwd, listOf(10, 15, 30, 45, 60))
                store.skipForwardSec = skipFwd
            }) { Text("Skip fwd: ${skipFwd}s") }
        }
    }
}

private fun nextIn(current: Int, options: List<Int>): Int {
    val idx = options.indexOf(current)
    return options[(idx + 1).mod(options.size)]
}

fun formatTime(ms: Long): String {
    val totalSec = (ms / 1000).coerceAtLeast(0)
    val h = totalSec / 3600
    val m = (totalSec % 3600) / 60
    val s = totalSec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
