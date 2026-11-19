import 'emby_api.dart';

/// A book as a single timeline over one or more files ("tracks").
///
/// Emby reports position and chapters against the whole book, so every
/// seek and every progress report converts between the book-global
/// position and the (track, offset) pair the player actually uses.
class BookSession {
  final EmbyItem item;
  final List<MediaSourceDto> sources;
  final String playSessionId;

  /// For album books (several Audio items presented as one book):
  /// the owning item id per source, aligned with [sources]. Null
  /// when every source belongs to [item] (the single-item case).
  final List<String>? trackItemIds;

  /// Play session id per source, aligned with [sources].
  final List<String>? trackPlaySessionIds;

  /// Start offset of each track within the book, in milliseconds.
  late final List<int> trackStartsMs;

  /// Total book length in ms; 0 when the server didn't tell us.
  late final int totalMs;

  late final List<ChapterDto> chapters;

  BookSession(this.item, this.sources, this.playSessionId,
      {this.trackItemIds, this.trackPlaySessionIds}) {
    final durations = sources
        .map((s) =>
            s.runTimeTicks != null ? EmbyApi.ticksToMs(s.runTimeTicks!) : 0)
        .toList();
    final starts = List<int>.filled(sources.length, 0);
    var acc = 0;
    for (var i = 0; i < sources.length; i++) {
      starts[i] = acc;
      acc += durations[i];
    }
    trackStartsMs = starts;
    totalMs =
        item.runTimeTicks != null ? EmbyApi.ticksToMs(item.runTimeTicks!) : acc;
    chapters = [...item.chapters]
      ..sort((a, b) => a.startPositionTicks.compareTo(b.startPositionTicks));
  }

  /// Convert a book-global position to a (track index, offset within
  /// track) record.
  (int, int) locate(int globalMs) {
    if (sources.isEmpty) return (0, 0);
    var idx = 0;
    for (var i = 0; i < sources.length; i++) {
      if (globalMs >= trackStartsMs[i]) idx = i;
    }
    final offset = globalMs - trackStartsMs[idx];
    return (idx, offset < 0 ? 0 : offset);
  }

  int globalMs(int trackIndex, int offsetMs) {
    final start =
        (trackIndex >= 0 && trackIndex < trackStartsMs.length)
            ? trackStartsMs[trackIndex]
            : 0;
    return start + offsetMs;
  }

  int chapterStartMs(ChapterDto chapter) =>
      EmbyApi.ticksToMs(chapter.startPositionTicks);

  /// Where a position report for [globalMs] belongs: the item id,
  /// play session id and position (ms) to report. Single-item books
  /// report the book-global position against the item itself; album
  /// books report the position within the current file against that
  /// file, because Emby keeps resume points per file.
  (String, String, int) reportTarget(int globalMs) {
    final ids = trackItemIds;
    if (ids == null || ids.isEmpty) return (item.id, playSessionId, globalMs);
    final (idx, offset) = locate(globalMs);
    final i = idx < ids.length ? idx : ids.length - 1;
    final sessions = trackPlaySessionIds;
    final sid = (sessions != null && i < sessions.length)
        ? sessions[i]
        : playSessionId;
    return (ids[i], sid, offset);
  }

  int currentChapterIndex(int globalMs) {
    var idx = -1;
    for (var i = 0; i < chapters.length; i++) {
      if (globalMs >= chapterStartMs(chapters[i])) idx = i;
    }
    return idx;
  }
}
