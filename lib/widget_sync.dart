import 'dart:io';

import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Publishes the current book to the home-screen widget: title,
/// author, play state, and the cover art (downloaded once per book
/// to a local file the native widget reads). Best-effort only -
/// the widget must never break playback.
class WidgetSync {
  static String? _lastArtUri;
  static String _lastTitle = '';

  static Future<void> publish({
    required String title,
    required String artist,
    required bool playing,
    required Uri? artUri,
  }) async {
    try {
      if (title != _lastTitle) {
        _lastTitle = title;
        await HomeWidget.saveWidgetData<String>('title', title);
        await HomeWidget.saveWidgetData<String>('artist', artist);
      }
      final art = artUri?.toString();
      if (art != null && art != _lastArtUri) {
        _lastArtUri = art;
        final resp = await http.get(Uri.parse(art));
        if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/widget_cover.jpg');
          await file.writeAsBytes(resp.bodyBytes, flush: true);
          await HomeWidget.saveWidgetData<String>('coverPath', file.path);
        }
      }
      await HomeWidget.saveWidgetData<bool>('playing', playing);
      await HomeWidget.updateWidget(androidName: 'BookWidgetProvider');
    } catch (_) {
      // Widget is a nicety; playback comes first.
    }
  }
}
