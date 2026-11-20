import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

import 'audio_handler.dart';
import 'book_session.dart';
import 'crash_log.dart';
import 'emby_api.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'session_store.dart';

/// Startup is deliberately minimal: crash capture, then runApp.
///
/// v0.2.0 awaited the session store, the audio session and
/// AudioService.init BEFORE runApp — and on device the app sat on a
/// blank screen forever: no first frame, no crash, nothing to see.
/// From v0.2.1 the first frame goes up immediately, the store loads
/// behind a visible loading screen, and the whole playback stack
/// (audio session + audio_service) initialises lazily at the first
/// book open — the same rule the native build learned in v0.1.2:
/// startup never touches playback, so the sign-in screen is always
/// reachable and any playback-init failure surfaces as an error the
/// user can see (and screenshot) instead of a blank screen.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CrashLog.init();
  CrashLog.install();
  runApp(const AudiobooksApp());
}

enum _Screen { loading, login, library, player, settings, error }

class AudiobooksApp extends StatefulWidget {
  const AudiobooksApp({super.key});

  @override
  State<AudiobooksApp> createState() => _AudiobooksAppState();
}

class _AudiobooksAppState extends State<AudiobooksApp> {
  SessionStore? _store;
  EmbyApi? _api;
  _Screen _screen = _Screen.loading;
  BookSession? _playerSession;
  bool _openingBook = false;
  String? _crash;
  String? _errorText;

  BookAudioHandler? _handler;
  Future<BookAudioHandler>? _handlerFuture;

  @override
  void initState() {
    super.initState();
    _crash = CrashLog.read();
    if (_crash == null) {
      _loadStore();
    }
  }

  Future<void> _loadStore() async {
    try {
      final store = await SessionStore.load();
      if (!mounted) return;
      setState(() {
        _store = store;
        if (store.isSignedIn) {
          _api = EmbyApi(store.server, store.deviceId,
              token: store.token, userId: store.userId);
          _screen = _Screen.library;
        } else {
          _screen = _Screen.login;
        }
      });
    } catch (e, st) {
      CrashLog.record(e, st);
      if (!mounted) return;
      setState(() {
        _errorText = 'Could not load the saved sign-in.\n\n$e\n\n$st';
        _screen = _Screen.error;
      });
    }
  }

  /// The playback stack, built once, on first use.
  Future<BookAudioHandler> _ensureHandler() {
    return _handlerFuture ??= _initHandler();
  }

  Future<BookAudioHandler> _initHandler() async {
    // Audio focus: DUCK, never pause, for transient sounds. The
    // stock speech() recipe sounds right for audiobooks but actually
    // requests full "gain" focus with willPauseWhenDucked=true - so
    // every notification paused the book, and on focus return the
    // player could stall silent while still showing "playing" (the
    // exact Emby-app behaviour this app exists to escape). Keeping
    // the speech attributes but switching to transient-may-duck
    // gain with willPauseWhenDucked=false makes Android lower the
    // book's volume for the notification and restore it after -
    // the Symfonium behaviour.
    final audioSession = await AudioSession.instance;
    await audioSession.configure(AudioSessionConfiguration.speech().copyWith(
      androidAudioFocusGainType:
          AndroidAudioFocusGainType.gainTransientMayDuck,
      androidWillPauseWhenDucked: false,
    ));
    final handler = await AudioService.init(
      builder: () => BookAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'net.kellydev.audiobooks.channel.audio',
        androidNotificationChannelName: 'Audiobook playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    _handler = handler;
    return handler;
  }

  Future<void> _openBook(EmbyItem item, {bool autoplay = true}) async {
    final api = _api;
    if (api == null || _openingBook) return;
    setState(() => _openingBook = true);
    try {
      final handler = await _ensureHandler().timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
            'The playback service took too long to start. '
            'If this repeats, the error screen text is the clue — '
            'please screenshot it.'),
      );
      EmbyItem details;
      try {
        details = await api.itemDetails(item.id);
      } catch (_) {
        details = item;
      }
      final BookSession session;
      if (item.type == 'MusicAlbum') {
        // A "book" on this server is an album of Audio files.
        final children = await api.albumChildren(item.id);
        if (children.isEmpty) {
          throw Exception('This album has no playable audio files.');
        }
        if (children.length == 1) {
          // One-file book: open the file itself, so its own resume
          // position and chapters drive the session.
          final child = children.first;
          EmbyItem childDetails;
          try {
            childDetails = await api.itemDetails(child.id);
          } catch (_) {
            childDetails = child;
          }
          final info = await api.playbackInfo(child.id);
          session = await handler.loadBook(api, childDetails, info,
              listItem: child,
              autoplay: autoplay,
              rewindSec: _store?.resumeRewindSec ?? 20,
              initialSpeed: _store?.speedFor(child.id));
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
          session = await handler.loadAlbumBook(api, details, parts,
              listItem: item,
              autoplay: autoplay,
              rewindSec: _store?.resumeRewindSec ?? 20,
              initialSpeed: _store?.speedFor(item.id));
        }
      } else {
        final info = await api.playbackInfo(item.id);
        session = await handler.loadBook(api, details, info,
            listItem: item,
            autoplay: autoplay,
            rewindSec: _store?.resumeRewindSec ?? 20,
            initialSpeed: _store?.speedFor(item.id));
      }
      if (!mounted) return;
      setState(() {
        _playerSession = session;
        _screen = _Screen.player;
      });
    } catch (e, st) {
      CrashLog.record(e, st);
      if (!mounted) return;
      setState(() {
        _errorText = 'Could not open "${item.name}".\n\n$e\n\n$st';
        _screen = _Screen.error;
      });
    } finally {
      if (mounted) setState(() => _openingBook = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audiobooks for Emby',
      // Themed on the app icon (Timothy's artwork): layered greens on a
      // near-black backdrop. The app runs in the dark scheme to match.
      themeMode: ThemeMode.dark,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF46A34E)),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF46A34E),
        scaffoldBackgroundColor: const Color(0xFF0D0E11),
      ),
      home: _body(),
    );
  }

  Widget _body() {
    final crash = _crash;
    if (crash != null) {
      return _TraceScreen(
        title: 'The app crashed last time',
        intro: "Here's the recorded error. A screenshot of this screen is "
            'enough to pinpoint the fault.',
        trace: crash,
        buttonLabel: 'Dismiss and continue',
        onPressed: () {
          CrashLog.clear();
          setState(() {
            _crash = null;
            _screen = _Screen.loading;
          });
          _loadStore();
        },
      );
    }
    switch (_screen) {
      case _Screen.loading:
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading…'),
              ],
            ),
          ),
        );
      case _Screen.error:
        return _TraceScreen(
          title: 'Something went wrong',
          intro: 'A screenshot of this screen is enough to pinpoint the '
              'fault.',
          trace: _errorText ?? 'Unknown error',
          buttonLabel: 'Back',
          onPressed: () => setState(() => _screen =
              _api != null ? _Screen.library : _Screen.login),
        );
      case _Screen.login:
        final store = _store;
        if (store == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return LoginScreen(
          store: store,
          onSignedIn: (api) => setState(() {
            _api = api;
            _screen = _Screen.library;
          }),
        );
      case _Screen.library:
        final api = _api;
        final store = _store;
        if (api == null || store == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return LibraryScreen(
          api: api,
          store: store,
          openingBook: _openingBook,
          onOpenBook: (item, autoplay) =>
              _openBook(item, autoplay: autoplay),
          onOpenSettings: () => setState(() => _screen = _Screen.settings),
          onSignOut: () async {
            await _handler?.stopAndClear();
            _store?.signOut();
            setState(() {
              _api = null;
              _screen = _Screen.login;
            });
          },
        );
      case _Screen.settings:
        final store = _store;
        if (store == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return SettingsScreen(
          store: store,
          api: _api,
          onBack: () => setState(() => _screen = _Screen.library),
        );
      case _Screen.player:
        final api = _api;
        final session = _playerSession;
        final handler = _handler;
        final store = _store;
        if (api == null || session == null || handler == null || store == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return PlayerScreen(
          api: api,
          store: store,
          handler: handler,
          session: session,
          onBack: () => setState(() => _screen = _Screen.library),
        );
    }
  }
}

class _TraceScreen extends StatelessWidget {
  final String title;
  final String intro;
  final String trace;
  final String buttonLabel;
  final VoidCallback onPressed;
  const _TraceScreen({
    required this.title,
    required this.intro,
    required this.trace,
    required this.buttonLabel,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(intro, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    trace,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: onPressed, child: Text(buttonLabel)),
            ],
          ),
        ),
      ),
    );
  }
}
