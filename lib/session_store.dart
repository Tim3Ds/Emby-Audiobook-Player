import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists the sign-in session and player preferences on-device.
/// The token stays on this device only.
class SessionStore {
  final SharedPreferences _prefs;
  SessionStore(this._prefs);

  static Future<SessionStore> load() async =>
      SessionStore(await SharedPreferences.getInstance());

  static const defaultServer = 'https://emby.kellydev.net';

  String get server => _prefs.getString('server') ?? defaultServer;
  set server(String v) => _prefs.setString('server', v);

  String get username => _prefs.getString('username') ?? '';
  set username(String v) => _prefs.setString('username', v);

  String get userId => _prefs.getString('userId') ?? '';
  set userId(String v) => _prefs.setString('userId', v);

  String get token => _prefs.getString('token') ?? '';
  set token(String v) => _prefs.setString('token', v);

  String get deviceId {
    final existing = _prefs.getString('deviceId');
    if (existing != null) return existing;
    final created = _uuidV4();
    _prefs.setString('deviceId', created);
    return created;
  }

  int get skipForwardSec => _prefs.getInt('skipForwardSec') ?? 30;
  set skipForwardSec(int v) => _prefs.setInt('skipForwardSec', v);

  int get skipBackSec => _prefs.getInt('skipBackSec') ?? 15;
  set skipBackSec(int v) => _prefs.setInt('skipBackSec', v);

  bool get isSignedIn => token.isNotEmpty && userId.isNotEmpty;

  void signOut() {
    _prefs.remove('token');
    _prefs.remove('userId');
  }

  static String _uuidV4() {
    final rnd = Random.secure();
    final b = List<int>.generate(16, (_) => rnd.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String hex(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${hex(0)}${hex(1)}${hex(2)}${hex(3)}-${hex(4)}${hex(5)}-'
        '${hex(6)}${hex(7)}-${hex(8)}${hex(9)}-'
        '${hex(10)}${hex(11)}${hex(12)}${hex(13)}${hex(14)}${hex(15)}';
  }
}
