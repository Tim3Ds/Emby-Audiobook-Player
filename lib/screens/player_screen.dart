import 'dart:async';

import 'package:flutter/material.dart';

import '../audio_handler.dart';
import '../book_session.dart';
import '../emby_api.dart';
import '../session_store.dart';

class PlayerScreen extends StatefulWidget {
  final EmbyApi api;
  final SessionStore store;
  final BookAudioHandler handler;
  final BookSession session;
  final VoidCallback onBack;
  const PlayerScreen({
    super.key,
    required this.api,
    required this.store,
    required this.handler,
    required this.session,
    required this.onBack,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Timer? _poll;
  bool _isPlaying = false;
  int _globalMs = 0;
  int _trackIndex = 0;
  double _speed = 1.0;
  late int _skipFwd = widget.store.skipForwardSec;
  late int _skipBack = widget.store.skipBackSec;
  bool _scrubbing = false;
  double _scrubMs = 0;

  BookSession get session => widget.session;
  BookAudioHandler get handler => widget.handler;

  @override
  void initState() {
    super.initState();
    _sync();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _sync());
  }

  void _sync() {
    if (!mounted) return;
    setState(() {
      _isPlaying = handler.player.playing;
      _trackIndex = handler.player.currentIndex ?? 0;
      _globalMs = handler.globalPositionMs;
      _speed = handler.player.speed;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Deliberately NO stop report here: leaving the player screen is
    // the normal flow while the book keeps playing in the background.
    // Reporting Stopped here (the old behaviour) closed the Emby
    // session AND cancelled the handler's progress timer, so the
    // position never updated again for the rest of the book - the
    // exact opposite of cross-device pickup. The handler owns all
    // reporting; it stops only when playback truly stops.
    super.dispose();
  }

  void _seekGlobal(int targetMs) {
    handler.seekGlobal(targetMs);
    setState(() => _globalMs = targetMs.clamp(
        0, session.totalMs > 0 ? session.totalMs : targetMs));
  }

  String _formatTime(int ms) {
    final totalSec = ms ~/ 1000 < 0 ? 0 : ms ~/ 1000;
    final h = totalSec ~/ 3600;
    final m = (totalSec % 3600) ~/ 60;
    final s = totalSec % 60;
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:$ss';
    }
    return '$m:$ss';
  }

  int _nextIn(int current, List<int> options) {
    final idx = options.indexOf(current);
    return options[(idx + 1) % options.length];
  }

  String _sleepLabel() {
    if (handler.sleepChapterArmed) return 'Sleep: end of chapter';
    final r = handler.sleepRemaining;
    if (r == null) return 'Sleep timer';
    final m = r.inMinutes + (r.inSeconds % 60 > 0 ? 1 : 0);
    return 'Sleep: ${m}m left';
  }

  void _showSleepOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('Off'),
              onTap: () {
                handler.cancelSleep();
                Navigator.pop(ctx);
                setState(() {});
              },
            ),
            for (final mins in [5, 10, 15, 30, 45, 60])
              ListTile(
                title: Text('$mins minutes'),
                onTap: () {
                  handler.armSleepIn(Duration(minutes: mins));
                  Navigator.pop(ctx);
                  setState(() {});
                },
              ),
            if (session.chapters.length > 1)
              ListTile(
                title: const Text('End of chapter'),
                onTap: () {
                  handler.armSleepEndOfChapter();
                  Navigator.pop(ctx);
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showChapterList() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          itemCount: session.chapters.length,
          itemBuilder: (ctx, i) {
            final ch = session.chapters[i];
            final current = i == session.currentChapterIndex(_globalMs);
            final name =
                ch.name.trim().isEmpty ? 'Chapter ${i + 1}' : ch.name;
            return ListTile(
              leading: Icon(
                  current ? Icons.play_arrow : Icons.bookmark_border,
                  size: 20),
              title: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_formatTime(ch.startPositionTicks ~/ 10000)),
              selected: current,
              onTap: () {
                Navigator.pop(ctx);
                _seekGlobal(ch.startPositionTicks ~/ 10000);
              },
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapterIdx = session.currentChapterIndex(_globalMs);
    final chapterName = (chapterIdx >= 0 &&
            session.chapters[chapterIdx].name.trim().isNotEmpty)
        ? session.chapters[chapterIdx].name
        : null;
    final shownMs = _scrubbing ? _scrubMs : _globalMs.toDouble();
    // Chapter label with ONE numbering. Emby chapter names often
    // embed their own number ("Chapter 21") that can disagree with
    // the chapter's actual position (22nd of 42), which made the
    // label look off by one. A leading "Chapter N" in the name is
    // dropped; the position shown is always the true index.
    String? chapterLabel;
    if (chapterIdx >= 0) {
      final total = session.chapters.length;
      final raw = chapterName ?? '';
      final m = RegExp(r'^\s*chapter\s+\d+\s*[-:.)]?\s*',
              caseSensitive: false)
          .firstMatch(raw);
      final title = m != null ? raw.substring(m.end).trim() : raw.trim();
      chapterLabel = total > 1
          ? (title.isEmpty
              ? 'Chapter ${chapterIdx + 1} of $total'
              : '$title (${chapterIdx + 1}/$total)')
          : (title.isEmpty ? 'Chapter ${chapterIdx + 1}' : title);
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to library',
                    onPressed: widget.onBack,
                  ),
                  Text('Now Playing',
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 8),
              if (session.item.hasCover) ...[
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      widget.api.imageUrl(session.item.coverItemId),
                      width: 220,
                      height: 220,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Text(session.item.name,
                  style: Theme.of(context).textTheme.headlineSmall),
              if (session.item.author.isNotEmpty)
                Text(session.item.author,
                    style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 4),
              Text(
                [
                  if (session.sources.length > 1)
                    'Track ${_trackIndex + 1} of ${session.sources.length}',
                  if (chapterLabel != null) chapterLabel,
                ].join(' · '),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              if (session.totalMs > 0) ...[
                Slider(
                  value: shownMs.clamp(0, session.totalMs.toDouble()),
                  max: session.totalMs.toDouble(),
                  onChanged: (v) => setState(() {
                    _scrubbing = true;
                    _scrubMs = v;
                  }),
                  onChangeEnd: (v) {
                    _seekGlobal(v.toInt());
                    setState(() => _scrubbing = false);
                  },
                ),
                Row(
                  children: [
                    Text(_formatTime(shownMs.toInt()),
                        style: Theme.of(context).textTheme.bodySmall),
                    const Spacer(),
                    Text(
                        '-${_formatTime(session.totalMs - shownMs.toInt())}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              // Main transport: prev track | skip back | play/pause | skip fwd | next track
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (session.sources.length > 1)
                    IconButton(
                      icon: const Icon(Icons.skip_previous, size: 32),
                      tooltip: 'Previous track',
                      onPressed: () => handler.skipToPrevious(),
                    )
                  else
                    // Single-file book: no track buttons to grey out.
                    const SizedBox(width: 48),
                  Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.replay, size: 32),
                        tooltip: 'Skip back',
                        onPressed: () =>
                            _seekGlobal(_globalMs - _skipBack * 1000),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: Theme.of(context).textTheme.labelSmall,
                        ),
                        onPressed: () => setState(() {
                          _skipBack =
                              _nextIn(_skipBack, const [5, 10, 15, 30]);
                          widget.store.skipBackSec = _skipBack;
                        }),
                        child: Text('-${_skipBack}s'),
                      ),
                    ],
                  ),
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: FilledButton(
                      style: FilledButton.styleFrom(shape: const CircleBorder()),
                      onPressed: () =>
                          _isPlaying ? handler.pause() : handler.play(),
                      child: _isPlaying
                          ? const Icon(Icons.pause, size: 36)
                          : Transform.translate(
                              // The play_arrow glyph's own bounding
                              // box sits right of centre in its grid
                              // (path spans x 8..19 of 24), so the
                              // stock icon already renders right-
                              // shifted in the circle; v0.3.7 nudged
                              // it further right and it looked wrong.
                              // Shift it back by exactly that built-in
                              // offset (1.5/24 of 36dp = 2.25dp) so
                              // the triangle's box is centred.
                              offset: const Offset(-2.25, 0),
                              child: const Icon(Icons.play_arrow, size: 36),
                            ),
                    ),
                  ),
                  Column(
                    children: [
                      IconButton(
                        // Mirrored replay icon: number-free, matching
                        // the back button. (The old forward_30 glyph
                        // claimed 30s whatever the real setting was.)
                        icon: Transform(
                          alignment: Alignment.center,
                          transform: Matrix4.identity()..scale(-1.0, 1.0),
                          child: const Icon(Icons.replay, size: 32),
                        ),
                        tooltip: 'Skip forward',
                        onPressed: () =>
                            _seekGlobal(_globalMs + _skipFwd * 1000),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: Theme.of(context).textTheme.labelSmall,
                        ),
                        onPressed: () => setState(() {
                          _skipFwd =
                              _nextIn(_skipFwd, const [10, 15, 30, 45, 60]);
                          widget.store.skipForwardSec = _skipFwd;
                        }),
                        child: Text('+${_skipFwd}s'),
                      ),
                    ],
                  ),
                  if (session.sources.length > 1)
                    IconButton(
                      icon: const Icon(Icons.skip_next, size: 32),
                      tooltip: 'Next track',
                      onPressed: () => handler.skipToNext(),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
              if (session.chapters.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: () => handler.prevChapter(),
                      child: const Text('‹  Prev chapter'),
                    ),
                    TextButton.icon(
                      icon: const Icon(Icons.list, size: 18),
                      label: const Text('Chapters'),
                      onPressed: _showChapterList,
                    ),
                    TextButton(
                      onPressed: () => handler.nextChapter(),
                      child: const Text('Next chapter  ›'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Center(
                child: TextButton.icon(
                  icon: const Icon(Icons.bedtime_outlined, size: 20),
                  label: Text(_sleepLabel()),
                  onPressed: _showSleepOptions,
                ),
              ),
              const SizedBox(height: 16),
              // Playback speed
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final s in [0.75, 1.0, 1.25, 1.5, 2.0])
                    ChoiceChip(
                      label: Text('${s}×'),
                      selected: _speed == s,
                      onSelected: (_) {
                        handler.setSpeed(s);
                        widget.store.setSpeedFor(session.item.id, s);
                        setState(() => _speed = s);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
