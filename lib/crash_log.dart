import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Last-resort crash capture for a sideloaded app with no Play Console:
/// records the stack trace of an uncaught error to a file, so the next
/// launch can show it on screen instead of the app just dying silently.
/// (Carried over from the native build, where this earned its keep.)
class CrashLog {
  static const _fileName = 'last-crash.txt';
  static File? _file;

  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/$_fileName');
    } catch (_) {
      _file = null;
    }
  }

  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(details.exception, details.stack);
      previous?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack);
      return false;
    };
  }

  static void record(Object error, StackTrace? stack) {
    try {
      _file?.writeAsStringSync('$error\n\n${stack ?? ''}');
    } catch (_) {
      // Never let the crash reporter crash.
    }
  }

  static String? read() {
    try {
      final f = _file;
      if (f != null && f.existsSync()) {
        final text = f.readAsStringSync();
        return text.trim().isEmpty ? null : text;
      }
    } catch (_) {}
    return null;
  }

  static void clear() {
    try {
      _file?.deleteSync();
    } catch (_) {}
  }
}
