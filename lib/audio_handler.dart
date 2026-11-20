import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import 'book_session.dart';
import 'emby_api.dart';
import 'session_store.dart';
import 'widget_sync.dart';

/// Background playback handler (audio_service + just_audio).
///
/// The player lives here, not in the UI, so books keep playing with the
/// screen off, driven by the system media notification and lock-screen
/// controls. Audio focus is configured in main(): speech attributes
/// with transient-may-duck gain and willPauseWhenDucked=false, so a
/// notification sound DUCKS the book briefly instead of pausing it —
/// the exact behaviour the Emby app gets wrong. (The stock speech()
/// recipe pauses when ducked; see main.dart.) A watchdog below also
/// auto-recovers the rare stall where the player reports playing
/// but the position no longer advances.
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
      _publishWidget();
    });
    mediaItem.stream.listen((_) => _publishWidget());
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
      // A track boundary is a natural checkpoint: sync the position
      // so another device can pick up here.
      _reportProgress(isPaused: !player.playing);
    });
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        // The book truly ended: final Stopped report at the end
        // position (Emby marks it played) and the timer stops.
        reportStoppedNow();
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
    bool autoplay = true,
    int rewindSec = 0,
    double? initialSpeed,
  }) async {
    // Switching books: close out the previous book's session at its
    // current position first, so its place is saved too.
    if (session != null) reportStoppedNow();
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
    await _playSession(api, s, items, sources, startTicks,
        autoplay: autoplay, rewindSec: rewindSec, initialSpeed: initialSpeed);
    return s;
  }

  /// Open a MusicAlbum as one book over its files. Chapters from
  /// every file are merged onto the book timeline with their file
  /// offsets; position reports go to the file currently playing,
  /// because Emby keeps resume points per file.
  Future<BookSession> loadAlbumBook(
    EmbyApi api,
    EmbyItem albumDetails,
    List<({EmbyItem item, PlaybackInfoResponse info})> parts, {
    required EmbyItem listItem,
    bool autoplay = true,
    int rewindSec = 0,
    double? initialSpeed,
  }) async {
    if (session != null) reportStoppedNow();
    _api = api;

    final sources = <MediaSourceDto>[];
    final trackItemIds = <String>[];
    final trackPlaySessionIds = <String>[];
    final partStartTicks = <int>[];
    final mergedChapters = <ChapterDto>[];
    var accTicks = 0;
    for (final part in parts) {
      partStartTicks.add(accTicks);
      for (final src in part.info.mediaSources) {
        sources.add(src);
        trackItemIds.add(part.item.id);
        trackPlaySessionIds.add(part.info.playSessionId);
      }
      for (final ch in part.item.chapters) {
        mergedChapters.add(ChapterDto(
          startPositionTicks: ch.startPositionTicks + accTicks,
          name: ch.name,
        ));
      }
      accTicks += part.info.mediaSources
          .fold<int>(0, (a, s) => a + (s.runTimeTicks ?? 0));
    }
    if (sources.isEmpty) {
      throw Exception('None of this album\'s files could be played.');
    }
    mergedChapters
        .sort((a, b) => a.startPositionTicks.compareTo(b.startPositionTicks));

    final displayItem = EmbyItem(
      id: albumDetails.id,
      name: albumDetails.name,
      type: albumDetails.type,
      runTimeTicks: albumDetails.runTimeTicks,
      albumArtist: albumDetails.albumArtist,
      artists: albumDetails.artists,
      imageTags: albumDetails.imageTags,
      userData: albumDetails.userData,
      chapters: mergedChapters,
      // The album's own image endpoint 404s; its cover lives on
      // the first file.
      imageItemId: parts.first.item.id,
    );
    final s = BookSession(
      displayItem,
      sources,
      parts.first.info.playSessionId,
      trackItemIds: trackItemIds,
      trackPlaySessionIds: trackPlaySessionIds,
    );
    session = s;

    final items = <MediaItem>[];
    final audioSources = <AudioSource>[];
    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final mediaItem = MediaItem(
        id: source.id.isNotEmpty ? source.id : '${trackItemIds[i]}-$i',
        title: albumDetails.name,
        artist: albumDetails.author,
        artUri: Uri.tryParse(api.imageUrl(trackItemIds[i])),
        duration: source.runTimeTicks != null
            ? Duration(milliseconds: EmbyApi.ticksToMs(source.runTimeTicks!))
            : null,
      );
      items.add(mediaItem);
      audioSources.add(AudioSource.uri(
          Uri.parse(api.streamUrl(trackItemIds[i], source)),
          tag: mediaItem));
    }
    queue.add(items);

    // Start position: the album's own saved position wins; otherwise
    // the first file that has one (he plays files, and Emby keeps
    // their positions per file).
    var startTicks = listItem.userData?.playbackPositionTicks ??
        albumDetails.userData?.playbackPositionTicks ??
        0;
    if (startTicks == 0) {
      for (var i = 0; i < parts.length; i++) {
        final pos = parts[i].item.userData?.playbackPositionTicks ?? 0;
        if (pos > 0) {
          startTicks = partStartTicks[i] + pos;
          break;
        }
      }
    }
    await _playSession(api, s, items, audioSources, startTicks,
        autoplay: autoplay, rewindSec: rewindSec, initialSpeed: initialSpeed);
    return s;
  }

  /// Shared tail of loadBook / loadAlbumBook: queue the sources,
  /// start at the saved position, begin reporting.
  Future<void> _playSession(EmbyApi api, BookSession s,
      List<MediaItem> items, List<AudioSource> sources, int startTicks,
      {bool autoplay = true,
      int rewindSec = 0,
      double? initialSpeed}) async {
    // Resume rewind: back up a few seconds from the saved position
    // so the listener re-hears the thread of the story.
    var startMs = EmbyApi.ticksToMs(startTicks);
    if (rewindSec > 0 && startMs > 0) {
      final rewindMs = rewindSec * 1000;
      startMs = startMs > rewindMs ? startMs - rewindMs : 0;
    }
    final (trackIndex, offsetMs) = s.locate(startMs);
    if (trackIndex >= 0 && trackIndex < items.length) {
      mediaItem.add(items[trackIndex]);
    }
    await player.setAudioSources(
      sources,
      initialIndex: trackIndex,
      initialPosition: Duration(milliseconds: offsetMs),
    );
    if (autoplay) {
      // just_audio's play() future completes only when playback
      // STOPS, so awaiting it would hang the caller - and with it
      // the app's move to the player screen - for the entire book.
      // Fire it.
      unawaited(player.play().catchError((Object _) {}));
    }
    // With autoplay off (Favorites / Next Up, unless the setting
    // says otherwise) the book opens cued at its saved position,
    // paused - the user presses play when they mean it.
    if (initialSpeed != null && initialSpeed > 0) {
      await player.setSpeed(initialSpeed);
    }
    final (rItem, rSession, rMs) = s.reportTarget(startMs);
    api.reportPlaying(rItem, rSession, EmbyApi.msToTicks(rMs));
    if (!autoplay) _reportProgress(isPaused: true);
    _reportTimer?.cancel();
    _reportTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _reportProgress(isPaused: !player.playing);
    });
    _watchdog?.cancel();
    _lastPosMs = -1;
    _stallSince = null;
    _watchdog =
        Timer.periodic(const Duration(seconds: 1), (_) => _watchdogTick());
  }

  // ---- Sleep timer ----------------------------------------------------
  DateTime? _sleepDeadline;
  int? _sleepChapter;
  Timer? _sleepTimer;

  Duration? get sleepRemaining {
    final dl = _sleepDeadline;
    if (dl == null) return null;
    final r = dl.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  bool get sleepChapterArmed => _sleepChapter != null;

  void armSleepIn(Duration d) {
    _sleepDeadline = DateTime.now().add(d);
    _sleepChapter = null;
    _ensureSleepTimer();
  }

  void armSleepEndOfChapter() {
    final s = session;
    if (s == null) return;
    _sleepDeadline = null;
    _sleepChapter = s.currentChapterIndex(globalPositionMs);
    _ensureSleepTimer();
  }

  void cancelSleep() {
    _sleepDeadline = null;
    _sleepChapter = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  void _ensureSleepTimer() {
    _sleepTimer ??=
        Timer.periodic(const Duration(seconds: 2), (_) => _sleepTick());
  }

  void _sleepTick() {
    final dl = _sleepDeadline;
    if (dl != null && !DateTime.now().isBefore(dl)) {
      cancelSleep();
      unawaited(pause());
      return;
    }
    final sc = _sleepChapter;
    if (sc != null && sc >= 0) {
      final s = session;
      if (s != null && s.currentChapterIndex(globalPositionMs) > sc) {
        cancelSleep();
        unawaited(pause());
      }
    }
  }

  // ---- Stall watchdog -------------------------------------------------
  // If the player claims to be playing but the position has not
  // moved for several seconds, the audio stack has wedged - seen
  // after audio-focus interruptions: the UI shows "playing", no
  // sound comes out, and only a manual pause/play unwedges it.
  // Do that pause/play automatically. Ducking never trips this:
  // a ducked book's position keeps advancing.
  int _lastPosMs = -1;
  DateTime? _stallSince;
  bool _nudging = false;
  Timer? _watchdog;

  void _watchdogTick() {
    if (session == null) return;
    final pos = globalPositionMs;
    final wedged = player.playing &&
        player.processingState == ProcessingState.ready;
    if (!wedged || pos != _lastPosMs) {
      _lastPosMs = pos;
      _stallSince = null;
      return;
    }
    _stallSince ??= DateTime.now();
    if (!_nudging &&
        DateTime.now().difference(_stallSince!) >=
            const Duration(seconds: 3)) {
      _stallSince = null;
      _nudging = true;
      unawaited(_recoverStall());
    }
  }

  Future<void> _recoverStall() async {
    try {
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // play()'s future completes only when playback stops; never
      // await it (the loadBook lesson).
      unawaited(player.play().catchError((Object _) {}));
    } catch (_) {
      // Best effort only.
    } finally {
      _nudging = false;
    }
  }

  void _reportProgress({required bool isPaused}) {
    final api = _api;
    final s = session;
    if (api == null || s == null) return;
    final (id, sess, ms) = s.reportTarget(globalPositionMs);
    api.reportProgress(id, sess, EmbyApi.msToTicks(ms), isPaused);
  }

  /// The player screen was closed: tell Emby the session ended at the
  /// current position (playback itself continues in the background,
  /// matching the native build's behaviour).
  void reportStoppedNow() {
    final api = _api;
    final s = session;
    _reportTimer?.cancel();
    _reportTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    cancelSleep();
    if (api == null || s == null) return;
    final (id, sess, ms) = s.reportTarget(globalPositionMs);
    api.reportStopped(id, sess, EmbyApi.msToTicks(ms));
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
  Future<void> play() async {
    if (session == null) {
      // Media play with nothing loaded (widget button, headset,
      // notification): continue the most recent book instead of
      // doing nothing. This is also what makes the widget's play
      // button work after the app has been swiped away - the
      // media key restarts the service, and the handler picks
      // the book up itself.
      await _continueLastBook();
      return;
    }
    await player.play();
  }

  /// Load and play the most recent book from the saved sign-in,
  /// mirroring the app's open-book logic (album-aware). Silent
  /// and best-effort: any failure just leaves things stopped.
  Future<void> _continueLastBook() async {
    try {
      final store = await SessionStore.load();
      if (!store.isSignedIn) return;
      final api = EmbyApi(store.server, store.deviceId,
          token: store.token, userId: store.userId);
      EmbyItem? target;
      final lastId = store.lastBookId;
      if (lastId != null && lastId.isNotEmpty) {
        target = await api.itemDetails(lastId);
      } else {
        final resume = await api.resumeItems();
        if (resume.isNotEmpty) target = resume.first;
      }
      if (target == null) return;
      final item = target;
      if (item.type == 'MusicAlbum') {
        final children = await api.albumChildren(item.id);
        if (children.isEmpty) return;
        if (children.length == 1) {
          final child = children.first;
          EmbyItem childDetails;
          try {
            childDetails = await api.itemDetails(child.id);
          } catch (_) {
            childDetails = child;
          }
          final info = await api.playbackInfo(child.id);
          await loadBook(api, childDetails, info,
              listItem: child,
              autoplay: true,
              rewindSec: store.resumeRewindSec,
              initialSpeed: store.speedFor(child.id));
        } else {
          final parts = <({EmbyItem item, PlaybackInfoResponse info})>[];
          for (final child in children) {
            EmbyItem childDetails;
            try {
              childDetails = await api.itemDetails(child.id);
            } catch (_) {
              childDetails = child;
            }
            final info = await api.playbackInfo(child.id);
            parts.add((item: childDetails, info: info));
          }
          await loadAlbumBook(api, item, parts,
              listItem: item,
              autoplay: true,
              rewindSec: store.resumeRewindSec,
              initialSpeed: store.speedFor(item.id));
        }
      } else {
        final details = await api.itemDetails(item.id);
        final info = await api.playbackInfo(item.id);
        await loadBook(api, details, info,
            listItem: item,
            autoplay: true,
            rewindSec: store.resumeRewindSec,
            initialSpeed: store.speedFor(item.id));
      }
    } catch (_) {
      // Best effort only; opening the app still works.
    }
  }

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
  void _publishWidget() {
    final item = mediaItem.value;
    if (item == null) return;
    unawaited(WidgetSync.publish(
      title: item.title,
      artist: item.artist ?? '',
      playing: player.playing,
      artUri: item.artUri,
    ));
  }

  /// Media-session fast-forward / rewind (notification buttons,
  /// headset keys, the home-screen widget): skip by the configured
  /// seconds, not a continuous seek. Acts on press (begin) only.
  @override
  Future<void> seekForward(bool begin) async {
    if (!begin || session == null) return;
    final store = await SessionStore.load();
    await seekGlobal(globalPositionMs + store.skipForwardSec * 1000);
  }

  @override
  Future<void> seekBackward(bool begin) async {
    if (!begin || session == null) return;
    final store = await SessionStore.load();
    await seekGlobal(globalPositionMs - store.skipBackSec * 1000);
  }

  Future<void> seekGlobal(int globalMs) async {
    final s = session;
    if (s == null) return;
    var clamped = globalMs;
    if (clamped < 0) clamped = 0;
    if (s.totalMs > 0 && clamped > s.totalMs) clamped = s.totalMs;
    final (idx, offset) = s.locate(clamped);
    await player.seek(Duration(milliseconds: offset), index: idx);
    // Checkpoint seeks immediately, not at the next 10s tick.
    _reportProgress(isPaused: !player.playing);
  }

  @override
  Future<void> skipToNext() async {
    final s = session;
    if (s == null) return;
    final idx = player.currentIndex ?? 0;
    if (idx < s.sources.length - 1) {
      await player.seek(Duration.zero, index: idx + 1);
      _reportProgress(isPaused: !player.playing);
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
    _reportProgress(isPaused: !player.playing);
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
