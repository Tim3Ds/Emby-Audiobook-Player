package net.kellydev.audiobooks.player

import net.kellydev.audiobooks.data.ChapterDto
import net.kellydev.audiobooks.data.EmbyApi
import net.kellydev.audiobooks.data.EmbyItem
import net.kellydev.audiobooks.data.MediaSourceDto

/**
 * A book as a single timeline over one or more files ("tracks").
 *
 * Emby reports position and chapters against the whole book, so every
 * seek and every progress report converts between the book-global
 * position and the (track, offset) pair the player actually uses.
 */
class BookSession(
    val item: EmbyItem,
    val sources: List<MediaSourceDto>,
    val playSessionId: String,
) {
    /** Start offset of each track within the book, in milliseconds. */
    val trackStartsMs: LongArray

    /** Total book length in ms; 0 when the server didn't tell us. */
    val totalMs: Long

    val chapters: List<ChapterDto> = item.Chapters.sortedBy { it.StartPositionTicks }

    init {
        val durations = sources.map { s -> s.RunTimeTicks?.let { EmbyApi.ticksToMs(it) } ?: 0L }
        val starts = LongArray(sources.size)
        var acc = 0L
        for (i in sources.indices) {
            starts[i] = acc
            acc += durations[i]
        }
        trackStartsMs = starts
        totalMs = item.RunTimeTicks?.let { EmbyApi.ticksToMs(it) } ?: acc
    }

    /** Convert a book-global position to (track index, offset within track). */
    fun locate(globalMs: Long): Pair<Int, Long> {
        if (sources.isEmpty()) return 0 to 0L
        var idx = 0
        for (i in sources.indices) {
            if (globalMs >= trackStartsMs[i]) idx = i
        }
        // If a track's duration is unknown (0), later starts collapse onto it;
        // the loop above still lands on the last plausible track.
        return idx to (globalMs - trackStartsMs[idx]).coerceAtLeast(0L)
    }

    fun globalMs(trackIndex: Int, offsetMs: Long): Long =
        (trackStartsMs.getOrElse(trackIndex) { 0L } + offsetMs)

    fun chapterStartMs(chapter: ChapterDto): Long = EmbyApi.ticksToMs(chapter.StartPositionTicks)

    fun currentChapterIndex(globalMs: Long): Int {
        var idx = -1
        for (i in chapters.indices) {
            if (globalMs >= chapterStartMs(chapters[i])) idx = i
        }
        return idx
    }
}
