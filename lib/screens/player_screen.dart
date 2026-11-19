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

  @override
  Widget build(BuildContext context) {
    final chapterIdx = session.currentChapterIndex(_globalMs);
    final chapterName = (chapterIdx >= 0 &&
            session.chapters[chapterIdx].name.trim().isNotEmpty)
        ? session.chapters[chapterIdx].name
        : null;
    final shownMs = _scrubbing ? _scrubMs : _globalMs.toDouble();

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
              if (session.item.hasPrimaryImage) ...[
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      widget.api.imageUrl(session.item.id),
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
                  if (chapterName != null)
                    session.chapters.length > 1
                        ? '$chapterName (${chapterIdx + 1}/${session.chapters.length})'
                        : chapterName,
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
                    Text(_formatTime(session.totalMs),
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              // Main transport: prev track | skip back | play/pause | skip fwd | next track
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 32),
                    tooltip: 'Previous track',
                    onPressed: session.sources.length > 1
                        ? () => handler.skipToPrevious()
                        : null,
                  ),
                  Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.replay, size: 32),
                        tooltip: 'Skip back',
                        onPressed: () =>
                            _seekGlobal(_globalMs - _skipBack * 1000),
                      ),
                      Text('-${_skipBack}s',
                          style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: FilledButton(
                      style: FilledButton.styleFrom(shape: const CircleBorder()),
                      onPressed: () =>
                          _isPlaying ? handler.pause() : handler.play(),
                      child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow,
                          size: 36),
                    ),
                  ),
                  Column(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.forward_30, size: 32),
                        tooltip: 'Skip forward',
                        onPressed: () =>
                            _seekGlobal(_globalMs + _skipFwd * 1000),
                      ),
                      Text('+${_skipFwd}s',
                          style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 32),
                    tooltip: 'Next track',
                    onPressed: session.sources.length > 1
                        ? () => handler.skipToNext()
                        : null,
                  ),
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
                    TextButton(
                      onPressed: () => handler.nextChapter(),
                      child: const Text('Next chapter  ›'),
                    ),
                  ],
                ),
              ],
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
                        setState(() => _speed = s);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // Skip interval settings
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton(
                    onPressed: () => setState(() {
                      _skipBack = _nextIn(_skipBack, const [5, 10, 15, 30]);
                      widget.store.skipBackSec = _skipBack;
                    }),
                    child: Text('Skip back: ${_skipBack}s'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _skipFwd =
                          _nextIn(_skipFwd, const [10, 15, 30, 45, 60]);
                      widget.store.skipForwardSec = _skipFwd;
                    }),
                    child: Text('Skip fwd: ${_skipFwd}s'),
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
