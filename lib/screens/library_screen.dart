import 'package:flutter/material.dart';

import '../emby_api.dart';
import '../session_store.dart';
import '../series.dart';

class LibraryScreen extends StatefulWidget {
  final EmbyApi api;
  final SessionStore store;
  final void Function(EmbyItem item, bool autoplay) onOpenBook;
  final VoidCallback onOpenSettings;
  final VoidCallback onSignOut;
  final bool openingBook;
  const LibraryScreen({
    super.key,
    required this.api,
    required this.store,
    required this.onOpenBook,
    required this.onOpenSettings,
    required this.onSignOut,
    required this.openingBook,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  List<EmbyItem> _resume = const [];
  List<EmbyItem> _favorites = const [];
  List<NextUpEntry> _nextUp = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Companion-app workflow: he may have just favorited or
    // started a book in the Emby app. When he switches back, the
    // shelves should simply be current - no refresh button.
    if (state == AppLifecycleState.resumed &&
        !_loading &&
        !widget.openingBook) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Favorites are scoped to the book libraries (plus a duration
      // guard in the API layer) so music cannot leak in. There is
      // deliberately NO unscoped fallback: twice on device it
      // "rescued" an empty scoped result by replacing it with the
      // unscoped list, songs and all. An honestly empty shelf beats
      // a wrong one. Continue Listening needs no scoping - its
      // saved-position filter is the reliable mechanism.
      final bookLibs = await widget.api.bookLibraryIds();
      final resume = await widget.api.resumeItems();
      final favorites = await widget.api.favoriteItems(parentIds: bookLibs);
      // Next Up in Series needs a full scan of the book libraries.
      // It is best-effort: if the scan fails, the shelf just stays
      // hidden - the two shelves above are the app's core.
      var nextUp = const <NextUpEntry>[];
      if (bookLibs.isNotEmpty) {
        try {
          final scan = await widget.api.libraryAudioItems(bookLibs);
          nextUp = computeNextUp(scan,
              inProgressIds: resume.map((e) => e.id).toSet());
        } catch (_) {
          nextUp = const [];
        }
      }
      if (!mounted) return;
      setState(() {
        _resume = resume;
        _favorites = favorites;
        _nextUp = nextUp;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load your books: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Books'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: widget.onOpenSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: widget.onSignOut,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: _load, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  children: [
                    if (widget.openingBook)
                      const LinearProgressIndicator(),
                    _section(context, 'Continue Listening', _resume,
                        'Nothing in progress right now.'),
                    if (_nextUp.isNotEmpty)
                      _section(
                        context,
                        'Next Up in Series',
                        _nextUp.map((e) => e.item).toList(),
                        '',
                        autoplay: widget.store.autoplayFromLists,
                        subtitleFor: (item) {
                          final e = _nextUp.firstWhere(
                              (x) => x.item.id == item.id,
                              orElse: () => _nextUp.first);
                          return '${e.seriesName} · ${e.bookLabel}';
                        },
                      ),
                    _section(context, 'Favorites', _favorites,
                        'No favorite audiobooks yet — favorite a book in Emby and it shows up here.',
                        autoplay: widget.store.autoplayFromLists),
                  ],
                ),
    );
  }

  Widget _section(BuildContext context, String title, List<EmbyItem> items,
      String emptyText,
      {String? Function(EmbyItem)? subtitleFor, bool autoplay = true}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(emptyText,
                style: Theme.of(context).textTheme.bodyMedium),
          )
        else
          ...items.map((item) => _BookRow(
                api: widget.api,
                item: item,
                subtitleText: subtitleFor?.call(item),
                onTap: () => widget.onOpenBook(item, autoplay),
              )),
      ],
    );
  }
}

String _timeLeft(int ticks) {
  final raw = (ticks / 10000000 / 60).round();
  final mins = raw < 0 ? 0 : raw;
  if (mins < 60) return '$mins min left';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '${h}h left' : '${h}h ${m}m left';
}

class _BookRow extends StatelessWidget {
  final EmbyApi api;
  final EmbyItem item;
  final String? subtitleText;
  final VoidCallback onTap;
  const _BookRow(
      {required this.api,
      required this.item,
      this.subtitleText,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final positionTicks = item.userData?.playbackPositionTicks ?? 0;
    final totalTicks = item.runTimeTicks ?? 0;
    final progress = (positionTicks > 0 && totalTicks > 0)
        ? (positionTicks / totalTicks).clamp(0.0, 1.0)
        : null;
    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 64,
        child: item.hasCover
            ? Image.network(api.imageUrl(item.coverItemId),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.book, size: 32))
            : const Icon(Icons.book, size: 32),
      ),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitleText != null)
            Text(subtitleText!,
                maxLines: 1, overflow: TextOverflow.ellipsis)
          else if (item.author.isNotEmpty)
            Text(item.author, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 4),
            Text(_timeLeft(totalTicks - positionTicks),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
