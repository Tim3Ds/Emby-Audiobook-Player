import 'package:flutter/material.dart';

import '../emby_api.dart';

class LibraryScreen extends StatefulWidget {
  final EmbyApi api;
  final void Function(EmbyItem item) onOpenBook;
  final VoidCallback onSignOut;
  final bool openingBook;
  const LibraryScreen({
    super.key,
    required this.api,
    required this.onOpenBook,
    required this.onSignOut,
    required this.openingBook,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<EmbyItem> _resume = const [];
  List<EmbyItem> _favorites = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
      if (!mounted) return;
      setState(() {
        _resume = resume;
        _favorites = favorites;
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
                    _section(context, 'Favorites', _favorites,
                        'No favorite audiobooks yet — favorite a book in Emby and it shows up here.'),
                  ],
                ),
    );
  }

  Widget _section(
      BuildContext context, String title, List<EmbyItem> items, String emptyText) {
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
                onTap: () => widget.onOpenBook(item),
              )),
      ],
    );
  }
}

class _BookRow extends StatelessWidget {
  final EmbyApi api;
  final EmbyItem item;
  final VoidCallback onTap;
  const _BookRow({required this.api, required this.item, required this.onTap});

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
        child: item.hasPrimaryImage
            ? Image.network(api.imageUrl(item.id), fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.book, size: 32))
            : const Icon(Icons.book, size: 32),
      ),
      title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.author.isNotEmpty)
            Text(item.author, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (progress != null) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: progress),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
