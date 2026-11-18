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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CrashLog.init();
  CrashLog.install();
  final store = await SessionStore.load();

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

  runApp(AudiobooksApp(store: store, handler: handler));
}

enum _Screen { login, library, player }

class AudiobooksApp extends StatefulWidget {
  final SessionStore store;
  final BookAudioHandler handler;
  const AudiobooksApp({super.key, required this.store, required this.handler});

  @override
  State<AudiobooksApp> createState() => _AudiobooksAppState();
}

class _AudiobooksAppState extends State<AudiobooksApp> {
  late EmbyApi? _api;
  late _Screen _screen;
  BookSession? _playerSession;
  bool _openingBook = false;
  String? _crash;

  @override
  void initState() {
    super.initState();
    _crash = CrashLog.read();
    final store = widget.store;
    if (store.isSignedIn) {
      _api = EmbyApi(store.server, store.deviceId,
          token: store.token, userId: store.userId);
      _screen = _Screen.library;
    } else {
      _api = null;
      _screen = _Screen.login;
    }
  }

  Future<void> _openBook(EmbyItem item) async {
    final api = _api;
    if (api == null || _openingBook) return;
    setState(() => _openingBook = true);
    try {
      EmbyItem details;
      try {
        details = await api.itemDetails(item.id);
      } catch (_) {
        details = item;
      }
      final info = await api.playbackInfo(item.id);
      final session =
          await widget.handler.loadBook(api, details, info, listItem: item);
      if (!mounted) return;
      setState(() {
        _playerSession = session;
        _screen = _Screen.player;
      });
    } catch (e, st) {
      CrashLog.record(e, st);
    } finally {
      if (mounted) setState(() => _openingBook = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Audiobooks for Emby',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F5257)),
      home: _body(),
    );
  }

  Widget _body() {
    final crash = _crash;
    if (crash != null) {
      return _CrashScreen(
        trace: crash,
        onDismiss: () {
          CrashLog.clear();
          setState(() => _crash = null);
        },
      );
    }
    switch (_screen) {
      case _Screen.login:
        return LoginScreen(
          store: widget.store,
          onSignedIn: (api) => setState(() {
            _api = api;
            _screen = _Screen.library;
          }),
        );
      case _Screen.library:
        final api = _api;
        if (api == null) {
          return LoginScreen(
            store: widget.store,
            onSignedIn: (a) => setState(() {
              _api = a;
              _screen = _Screen.library;
            }),
          );
        }
        return LibraryScreen(
          api: api,
          openingBook: _openingBook,
          onOpenBook: _openBook,
          onSignOut: () async {
            await widget.handler.stopAndClear();
            widget.store.signOut();
            setState(() {
              _api = null;
              _screen = _Screen.login;
            });
          },
        );
      case _Screen.player:
        final api = _api;
        final session = _playerSession;
        if (api == null || session == null) {
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        }
        return PlayerScreen(
          api: api,
          store: widget.store,
          handler: widget.handler,
          session: session,
          onBack: () => setState(() => _screen = _Screen.library),
        );
    }
  }
}

class _CrashScreen extends StatelessWidget {
  final String trace;
  final VoidCallback onDismiss;
  const _CrashScreen({required this.trace, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('The app crashed last time',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                "Here's the recorded error. A screenshot of this screen is "
                'enough to pinpoint the fault.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    trace,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Dismiss and continue')),
            ],
          ),
        ),
      ),
    );
  }
}
