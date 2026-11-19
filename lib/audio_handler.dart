import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'book_session.dart';
import 'emby_api.dart';

/// Background playback handler (audio_service + just_audio).
///
/// The player lives here, not in the UI, so books keep playing with the
/// screen off, driven by the system media notification and lock-screen
/// controls. Audio focus is configured in main() with
/// AudioSessionConfiguration.speech(), whose Android gain type is
/// "transient may duck": a notification sound DUCKS the book briefly
/// instead of pausing/freezing it — the exact behaviour the Emby app
/// gets wrong.
///
/// Emby position sync lives here too: Playing on load, Progress every
/// ~10s and on pause, Stopped when the book is closed.
class BookAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer player = AudioPlayer();

  EmbyApi? _api;
  BookSession? session;
  Timer? _reportTimer;
  bool _wasPlaying = false;

  BookAudioHandler() {
    player.playbackEventStream.map(_transformEvent).pipe(playbackState);
    player.playingStream.listen((playing) {
      if (_wasPlaying && !playing) {
        _reportProgress(isPaused: true);
      }
      _wasPlaying = playing;
    });
    // Android draws the media notification and lock-screen controls
    // from the handler's current media item. Publishing only the queue
    // and playback state (v0.2.0-v0.2.5) left mediaItem unset, so on
    // device the audio played but no system controls ever appeared.
    // Keep mediaItem tracking the player's current source tag.
    player.sequenceStateStream.listen((sequenceState) {
      final tag = sequenceState.currentSource?.tag;
      if (tag is MediaItem) {
        mediaItem.add(tag);
      }
    });
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    final playing = player.playing;
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
    );
  }

  int get globalPositionMs {
    final s = session;
    if (s == null) return 0;
    return s.globalMs(
        player.currentIndex ?? 0, player.position.inMilliseconds);
  }

  /// Load a book and start it at the saved position. Returns the
  /// session the UI should present.
  Future<BookSession> loadBook(
    EmbyApi api,
    EmbyItem details,
    PlaybackInfoResponse info, {
    required EmbyItem listItem,
  }) async {
    _api = api;
    final s = BookSession(details, info.mediaSources, info.playSessionId);
    session = s;

    final items = <MediaItem>[];
    final sources = <AudioSource>[];
    for (var i = 0; i < info.mediaSources.length; i++) {
      final source = info.mediaSources[i];
      final mediaItem = MediaItem(
        id: source.id.isNotEmpty ? source.id : '${details.id}-$i',
        title: details.name,
        artist: details.author,
        artUri: Uri.tryParse(api.imageUrl(details.id)),
        duration: source.runTimeTicks != null
            ? Duration(milliseconds: EmbyApi.ticksToMs(source.runTimeTicks!))
            : null,
      );
      items.add(mediaItem);
      sources.add(
          AudioSource.uri(Uri.parse(api.streamUrl(details.id, source)), tag: mediaItem));
    }
    queue.add(items);

    final startTicks = listItem.userData?.playbackPositionTicks ??
        details.userData?.playbackPositionTicks ??
        0;
    final (trackIndex, offsetMs) = s.locate(EmbyApi.ticksToMs(startTicks));
    if (trackIndex >= 0 && trackIndex < items.length) {
      mediaItem.add(items[trackIndex]);
    }
    await player.setAudioSources(
      sources,
      initialIndex: trackIndex,
      initialPosition: Duration(milliseconds: offsetMs),
    );
    await player.play();
    api.reportPlaying(details.id, info.playSessionId, startTicks);
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _reportProgress(isPaused: !player.playing);
    });
    return s;
  }

  void _reportProgress({required bool isPaused}) {
    final api = _api;
    final s = session;
    if (api == null || s == null) return;
    api.reportProgress(s.item.id, s.playSessionId,
        EmbyApi.msToTicks(globalPositionMs), isPaused);
  }

  /// The player screen was closed: tell Emby the session ended at the
  /// current position (playback itself continues in the background,
  /// matching the native build's behaviour).
  void reportStoppedNow() {
    final api = _api;
    final s = session;
    _reportTimer?.cancel();
    _reportTimer = null;
    if (api == null || s == null) return;
    api.reportStopped(
        s.item.id, s.playSessionId, EmbyApi.msToTicks(globalPositionMs));
  }

  Future<void> stopAndClear() async {
    reportStoppedNow();
    session = null;
    _api = null;
    queue.add([]);
    await player.stop();
  }

  // ---- Transport -------------------------------------------------

  @override
  Future<void> play() => player.play();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    reportStoppedNow();
    await player.stop();
    await super.stop();
  }

  /// System seeks are within the current track.
  @override
  Future<void> seek(Duration position) =>
      player.seek(position, index: player.currentIndex);

  /// Book-global seek used by the app's own controls.
  Future<void> seekGlobal(int globalMs) async {
    final s = session;
    if (s == null) return;
    var clamped = globalMs;
    if (clamped < 0) clamped = 0;
    if (s.totalMs > 0 && clamped > s.totalMs) clamped = s.totalMs;
    final (idx, offset) = s.locate(clamped);
    await player.seek(Duration(milliseconds: offset), index: idx);
  }

  @override
  Future<void> skipToNext() async {
    final s = session;
    if (s == null) return;
    final idx = player.currentIndex ?? 0;
    if (idx < s.sources.length - 1) {
      await player.seek(Duration.zero, index: idx + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final idx = player.currentIndex ?? 0;
    if (player.position.inMilliseconds > 3000 || idx == 0) {
      await player.seek(Duration.zero, index: idx);
    } else {
      await player.seek(Duration.zero, index: idx - 1);
    }
  }

  void nextChapter() {
    final s = session;
    if (s == null) return;
    final g = globalPositionMs;
    for (final ch in s.chapters) {
      final start = s.chapterStartMs(ch);
      if (start > g + 500) {
        seekGlobal(start);
        return;
      }
    }
    skipToNext();
  }

  void prevChapter() {
    final s = session;
    if (s == null) return;
    final g = globalPositionMs;
    final current = s.currentChapterIndex(g);
    if (current < 0) return;
    final starts = s.chapters.map(s.chapterStartMs).toList();
    final intoChapter = g - starts[current];
    final target =
        (intoChapter > 3000 || current == 0) ? starts[current] : starts[current - 1];
    seekGlobal(target);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await player.setSpeed(speed);
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }
}
