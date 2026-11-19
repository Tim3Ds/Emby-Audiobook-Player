import 'dart:math' as math;

import 'emby_api.dart';

/// One row of the "Next Up in Series" shelf.
class NextUpEntry {
  final String seriesName;
  final String bookLabel; // e.g. "Book 6"
  final EmbyItem item;
  const NextUpEntry(this.seriesName, this.bookLabel, this.item);
}

class _SeriesBook {
  final EmbyItem item;
  final double number;
  const _SeriesBook(this.item, this.number);
}

final _bookPattern = RegExp(
    r'^(.+?)(?:\s+Series)?\s*,\s*Book\s+(\d+(?:\.\d+)?)',
    caseSensitive: false);

/// Parse (series name, book number) from an Audible-style file
/// name: "...: Imperium Spacemage Series, Book 4 [ASIN].m4b".
/// Emby stores no SeriesName for these items (verified against the
/// server) - the file name is the only place the series lives.
(String, double)? _parsePathSeries(String? path) {
  if (path == null) return null;
  final file = path.split('/').last;
  for (final segment in file.split(':')) {
    final m = _bookPattern.firstMatch(segment.trim());
    if (m != null) {
      final n = double.tryParse(m.group(2)!);
      if (n != null) return (m.group(1)!.trim(), n);
    }
  }
  return null;
}

bool _started(EmbyItem i) {
  final u = i.userData;
  if (u == null) return false;
  return u.playbackPositionTicks > 0 || u.played || u.playCount > 0;
}

String _fmtNum(double n) =>
    n == n.roundToDouble() ? '${n.toInt()}' : '$n';

/// Compute the next book for every series the user has started.
///
/// Two independent series shapes exist on this server:
///  - Album series: many books share one MusicAlbum and carry an
///    IndexNumber each (Star Force Universe: 93 box sets, numbered).
///    Only albums of LONG items count: a multi-file book is also an
///    "album", but its files are parts/chapters - on this server
///    even hour-long chapter files top out near 100 minutes, while
///    real books run 4+ hours, so the album route requires >= 4h
///    per item (verified against the library: the Wheel of Time
///    chapter albums are the false positives this excludes).
///  - Path series: each book is its own album, and the series name
///    + book number exist only in the file name (Spacemage).
///
/// "Next" is measured from the furthest book started in the
/// series. A candidate already in progress is not proposed.
List<NextUpEntry> computeNextUp(List<EmbyItem> scan,
    {required Set<String> inProgressIds}) {
  const longBookTicks = 144000000000; // 4 h in 100ns ticks
  final byAlbum = <String, List<_SeriesBook>>{};
  final bySeries = <String, List<_SeriesBook>>{};
  final seriesDisplay = <String, String>{};

  for (final item in scan) {
    final idx = item.indexNumber;
    if (item.albumId != null &&
        idx != null &&
        (item.runTimeTicks ?? 0) >= longBookTicks) {
      byAlbum
          .putIfAbsent(item.albumId!, () => [])
          .add(_SeriesBook(item, idx.toDouble()));
    }
    final parsed = _parsePathSeries(item.path);
    if (parsed != null) {
      final key = parsed.$1.toLowerCase();
      bySeries.putIfAbsent(key, () => []).add(_SeriesBook(item, parsed.$2));
      seriesDisplay[key] = parsed.$1;
    }
  }

  final results = <String, NextUpEntry>{};
  void consider(String display, List<_SeriesBook> books) {
    if (books.length < 2) return;
    if (books.map((b) => b.number).toSet().length < 2) return;
    final started = books.where((b) => _started(b.item)).toList();
    if (started.isEmpty) return;
    final furthest = started.map((b) => b.number).reduce(math.max);
    final upcoming = books.where((b) => b.number > furthest).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    if (upcoming.isEmpty) return;
    final candidate = upcoming.first.item;
    if (inProgressIds.contains(candidate.id)) return;
    if ((candidate.userData?.playbackPositionTicks ?? 0) > 0) return;
    results[display.toLowerCase()] = NextUpEntry(
        display, 'Book ${_fmtNum(upcoming.first.number)}', candidate);
  }

  // The path route runs first: where both routes see the same
  // series (Star Force), the file-name numbers cover more of the
  // series than the album's long items do, so the album route only
  // contributes series the path route did not name.
  bySeries.forEach((key, books) {
    consider(seriesDisplay[key]!, books);
  });
  byAlbum.forEach((albumId, books) {
    final display = books.first.item.album ?? 'Series';
    if (results.containsKey(display.toLowerCase())) return;
    consider(display, books);
  });

  final out = results.values.toList();
  out.sort((a, b) =>
      a.seriesName.toLowerCase().compareTo(b.seriesName.toLowerCase()));
  return out;
}
