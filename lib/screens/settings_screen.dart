import 'package:flutter/material.dart';

import '../emby_api.dart';
import '../session_store.dart';

/// A small settings screen: skip lengths, the list-autoplay
/// behaviour, and - deliberately visible rather than magic - how
/// the app decides what counts as an audiobook.
class SettingsScreen extends StatefulWidget {
  final SessionStore store;
  final EmbyApi? api;
  final VoidCallback onBack;
  const SettingsScreen({
    super.key,
    required this.store,
    required this.api,
    required this.onBack,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _skipBack = widget.store.skipBackSec;
  late int _skipFwd = widget.store.skipForwardSec;
  late bool _autoplay = widget.store.autoplayFromLists;
  late final Future<List<({String id, String name})>> _libraries =
      widget.api?.bookLibraries() ??
          Future.value(const <({String id, String name})>[]);

  int _nextIn(int current, List<int> options) {
    final idx = options.indexOf(current);
    return options[(idx + 1) % options.length];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to library',
          onPressed: widget.onBack,
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          _header(context, 'Playback'),
          ListTile(
            title: const Text('Skip back'),
            subtitle: const Text('Tap to change'),
            trailing: Text('${_skipBack}s',
                style: theme.textTheme.titleMedium),
            onTap: () => setState(() {
              _skipBack = _nextIn(_skipBack, const [5, 10, 15, 30]);
              widget.store.skipBackSec = _skipBack;
            }),
          ),
          ListTile(
            title: const Text('Skip forward'),
            subtitle: const Text('Tap to change'),
            trailing:
                Text('${_skipFwd}s', style: theme.textTheme.titleMedium),
            onTap: () => setState(() {
              _skipFwd = _nextIn(_skipFwd, const [10, 15, 30, 45, 60]);
              widget.store.skipForwardSec = _skipFwd;
            }),
          ),
          SwitchListTile(
            title: const Text('Autoplay from Favorites & Next Up'),
            subtitle: const Text('Start playing as soon as a book is '
                'opened from those shelves. Off: the book opens cued '
                'at its saved position, paused. Continue Listening '
                'always resumes playing.'),
            value: _autoplay,
            onChanged: (v) => setState(() {
              _autoplay = v;
              widget.store.autoplayFromLists = v;
            }),
          ),
          const Divider(),
          _header(context, 'How audiobooks are picked'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Only your Emby libraries of type "audiobooks" are '
              'looked in, and only two kinds of items count: audio '
              'files (a favorite file shorter than 15 minutes is '
              'treated as a song and skipped) and music albums - on '
              'your server each book is an album, and that is where '
              'Emby keeps its favorite flag. Series for Next Up are '
              'read from album order and from the "Series, Book N" '
              'in Audible-style file names, because Emby stores no '
              'series field for audio.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
          FutureBuilder<List<({String id, String name})>>(
            future: _libraries,
            builder: (context, snap) {
              final libs = snap.data;
              if (libs == null) {
                return const ListTile(
                  title: Text('Book libraries'),
                  subtitle: Text('Checking…'),
                );
              }
              if (libs.isEmpty) {
                return const ListTile(
                  title: Text('Book libraries'),
                  subtitle: Text('None detected'),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    title: Text('Book libraries'),
                    subtitle: Text('The shelves are scoped to these'),
                  ),
                  for (final lib in libs)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.library_books),
                      title: Text(lib.name),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}
