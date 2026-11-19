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

enum _Screen { loading, login, library, player, error }

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
    // Audio focus: the speech configuration uses Android's
    // "transient may duck" gain — notification sounds duck the book
    // instead of pausing it.
    final audioSession = await AudioSession.instance;
    await audioSession.configure(const AudioSessionConfiguration.speech());
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

  Future<void> _openBook(EmbyItem item) async {
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
      final info = await api.playbackInfo(item.id);
      final session =
          await handler.loadBook(api, details, info, listItem: item);
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
        if (api == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return LibraryScreen(
          api: api,
          openingBook: _openingBook,
          onOpenBook: _openBook,
          onSignOut: () async {
            await _handler?.stopAndClear();
            _store?.signOut();
            setState(() {
              _api = null;
              _screen = _Screen.login;
            });
          },
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
