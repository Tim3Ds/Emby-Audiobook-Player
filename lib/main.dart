import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

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
/// From v0.2.1 the first frame goes up immediately and the store
/// loads behind a visible loading screen. The playback stack is
/// still never AWAITED at startup — but since v0.4.13 its init is
/// kicked off unawaited from initState, for one reason: when
/// Android restarts the playback service after the process has
/// been killed (a headset or widget play press after a long
/// pause), the plugin boots this same engine headless and runs
/// main(), and the media key that started the service is silently
/// dropped unless a handler is registered by the time it lands.
/// Lazy init at first book open meant that path could never work:
/// no handler existed until the app was opened and a book tapped
/// — which was exactly the reported workaround. Eager-but-unawaited
/// init keeps the v0.2.1 guarantee (first frame immediately, init
/// failures still surface at book open, never as a blank screen)
/// while making the headless path real.
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

  bool _widgetContinuePending = false;

  @override
  void initState() {
    super.initState();
    _crash = CrashLog.read();
    if (_crash == null) {
      _loadStore();
    }
    // Safety net for the widget's old launch-intent path: builds
    // up to v0.4.6 sent play as an embyplayer://continue launch,
    // and a widget placed by one of those builds can still hold
    // that intent until its next refresh. (Since v0.4.8 the
    // buttons are silent media keys and the handler continues the
    // book itself.) A plugin hiccup here must not be recorded as
    // a crash, hence the catchError.
    HomeWidget.initiallyLaunchedFromHomeWidget()
        .then(_onWidgetUri)
        .catchError((Object _) {});
    HomeWidget.widgetClicked
        .listen(_onWidgetUri)
        .onError((Object _) {});
    // Register the playback handler right away (see the startup
    // note at main()): a media key that cold-starts the service
    // after process death is dropped by the platform side if no
    // handler is connected, so the handler must exist even when
    // nobody ever opens a book in this engine. Unawaited on
    // purpose — the first frame never waits on playback init,
    // and _ensureHandler's retry-on-error keeps a failed attempt
    // from being cached.
    unawaited(_ensureHandler());
  }

  void _onWidgetUri(Uri? uri) {
    if (uri == null || uri.host != 'continue') return;
    final handler = _handler;
    if (handler?.session != null) {
      // The widget button is play/pause: toggle the loaded book.
      if (handler!.player.playing) {
        handler.pause();
      } else {
        handler.play();
      }
      return;
    }
    _widgetContinuePending = true;
    _tryWidgetContinue();
  }

  Future<void> _tryWidgetContinue() async {
    if (!_widgetContinuePending) return;
    final api = _api;
    final store = _store;
    if (api == null || store == null) return; // retried once ready
    _widgetContinuePending = false;
    try {
      final item = await resolveContinueTarget(api, store);
      if (item != null && mounted) {
        await _openBook(item, autoplay: true);
      }
    } catch (_) {
      // A failed widget continue simply lands on the library.
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
      _tryWidgetContinue();
    } catch (e, st) {
      CrashLog.record(e, st);
      if (!mounted) return;
      setState(() {
        _errorText = 'Could not load the saved sign-in.\n\n$e\n\n$st';
        _screen = _Screen.error;
      });
    }
  }

  /// The playback stack, built once. Kicked off unawaited from
  /// initState (a headless service restart needs the handler
  /// registered before any media key lands) and awaited by the
  /// first book open. A failed init is NOT cached: the next book
  /// open retries from scratch instead of re-awaiting the same
  /// dead future until the app is restarted.
  Future<BookAudioHandler> _ensureHandler() {
    final f = _handlerFuture ??= _initHandler();
    f.then((_) {}, onError: (Object _) {
      if (identical(_handlerFuture, f)) _handlerFuture = null;
    });
    return f;
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
    _store?.lastBookId = item.id;
    setState(() => _openingBook = true);
    try {
      final handler = await _ensureHandler().timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
            'The playback service took too long to start. '
            'If this repeats, the error screen text is the clue — '
            'please screenshot it.'),
      );
      final session = await openBookItem(handler, api, item,
          autoplay: autoplay,
          rewindSec: _store?.resumeRewindSec ?? 20,
          speedFor: (id) => _store?.speedFor(id));
      if (!mounted) return;
      setState(() {
        _playerSession = session;
        _screen = _Screen.player;
      });
    } on BookLoadInterrupted {
      // A newer load (e.g. the widget's silent continue) won the
      // race for the player while this open was in flight. It
      // owns playback now; just land back on the library.
      if (!mounted) return;
      setState(() => _screen = _Screen.library);
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
      title: 'Emby Audiobook Player',
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
          onSignedIn: (api) {
            setState(() {
              _api = api;
              _screen = _Screen.library;
            });
            _tryWidgetContinue();
          },
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
