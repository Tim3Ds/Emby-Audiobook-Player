import 'dart:convert';

import 'package:http/http.dart' as http;

class UserDto {
  final String id;
  final String name;
  const UserDto({this.id = '', this.name = ''});
  factory UserDto.fromJson(Map<String, dynamic> j) =>
      UserDto(id: j['Id'] as String? ?? '', name: j['Name'] as String? ?? '');
}

class AuthResult {
  final String accessToken;
  final UserDto user;
  const AuthResult({this.accessToken = '', this.user = const UserDto()});
  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        accessToken: j['AccessToken'] as String? ?? '',
        user: j['User'] is Map<String, dynamic>
            ? UserDto.fromJson(j['User'] as Map<String, dynamic>)
            : const UserDto(),
      );
}

class UserDataDto {
  final int playbackPositionTicks;
  final double? playedPercentage;
  final bool isFavorite;
  final bool played;
  final int playCount;
  const UserDataDto({
    this.playbackPositionTicks = 0,
    this.playedPercentage,
    this.isFavorite = false,
    this.played = false,
    this.playCount = 0,
  });
  factory UserDataDto.fromJson(Map<String, dynamic> j) => UserDataDto(
        playbackPositionTicks: (j['PlaybackPositionTicks'] as num?)?.toInt() ?? 0,
        playedPercentage: (j['PlayedPercentage'] as num?)?.toDouble(),
        isFavorite: j['IsFavorite'] as bool? ?? false,
        played: j['Played'] as bool? ?? false,
        playCount: (j['PlayCount'] as num?)?.toInt() ?? 0,
      );
}

class ChapterDto {
  final int startPositionTicks;
  final String name;
  const ChapterDto({this.startPositionTicks = 0, this.name = ''});
  factory ChapterDto.fromJson(Map<String, dynamic> j) => ChapterDto(
        startPositionTicks: (j['StartPositionTicks'] as num?)?.toInt() ?? 0,
        name: j['Name'] as String? ?? '',
      );
}

class EmbyItem {
  final String id;
  final String name;
  final String type;
  final int? runTimeTicks;
  final String? path;
  final String? album;
  final String? albumId;
  final int? indexNumber;
  final String? albumArtist;
  final List<String> artists;
  final Map<String, dynamic> imageTags;
  final UserDataDto? userData;
  final List<ChapterDto> chapters;

  const EmbyItem({
    this.id = '',
    this.name = '',
    this.type = '',
    this.runTimeTicks,
    this.path,
    this.album,
    this.albumId,
    this.indexNumber,
    this.albumArtist,
    this.artists = const [],
    this.imageTags = const {},
    this.userData,
    this.chapters = const [],
  });

  factory EmbyItem.fromJson(Map<String, dynamic> j) => EmbyItem(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        type: j['Type'] as String? ?? '',
        runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
        path: j['Path'] as String?,
        album: j['Album'] as String?,
        albumId: j['AlbumId'] as String?,
        indexNumber: (j['IndexNumber'] as num?)?.toInt(),
        albumArtist: j['AlbumArtist'] as String?,
        artists: (j['Artists'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        imageTags: (j['ImageTags'] as Map?)?.cast<String, dynamic>() ?? const {},
        userData: j['UserData'] is Map<String, dynamic>
            ? UserDataDto.fromJson(j['UserData'] as Map<String, dynamic>)
            : null,
        chapters: (j['Chapters'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ChapterDto.fromJson)
                .toList() ??
            const [],
      );

  String get author =>
      albumArtist ?? (artists.isNotEmpty ? artists.first : '');
  bool get hasPrimaryImage => imageTags.containsKey('Primary');
}

class MediaSourceDto {
  final String id;
  final String name;
  final int? runTimeTicks;
  final String? container;
  final String? directStreamUrl;
  final String? transcodingUrl;
  const MediaSourceDto({
    this.id = '',
    this.name = '',
    this.runTimeTicks,
    this.container,
    this.directStreamUrl,
    this.transcodingUrl,
  });
  factory MediaSourceDto.fromJson(Map<String, dynamic> j) => MediaSourceDto(
        id: j['Id'] as String? ?? '',
        name: j['Name'] as String? ?? '',
        runTimeTicks: (j['RunTimeTicks'] as num?)?.toInt(),
        container: j['Container'] as String?,
        directStreamUrl: j['DirectStreamUrl'] as String?,
        transcodingUrl: j['TranscodingUrl'] as String?,
      );
}

class PlaybackInfoResponse {
  final List<MediaSourceDto> mediaSources;
  final String playSessionId;
  const PlaybackInfoResponse(
      {this.mediaSources = const [], this.playSessionId = ''});
  factory PlaybackInfoResponse.fromJson(Map<String, dynamic> j) =>
      PlaybackInfoResponse(
        mediaSources: (j['MediaSources'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(MediaSourceDto.fromJson)
                .toList() ??
            const [],
        playSessionId: j['PlaySessionId'] as String? ?? '',
      );
}

/// Minimal Emby API client covering exactly what this app needs:
/// sign-in, the resume list, the favorites list, item details (chapters),
/// playback info (stream URLs), and playback progress reporting so the
/// position stays synced with the server.
class EmbyApi {
  final String server;
  final String deviceId;
  String token;
  String userId;

  EmbyApi(this.server, this.deviceId, {this.token = '', this.userId = ''});

  String get base {
    var s = server.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  String get _authHeader =>
      'MediaBrowser Client="Audiobooks for Emby", Device="Android", '
      'DeviceId="$deviceId", Version="0.2.0"';

  Map<String, String> get _headers => {
        'X-Emby-Authorization': _authHeader,
        if (token.isNotEmpty) 'X-Emby-Token': token,
      };

  Future<String> _execute(http.Request request) async {
    final response =
        await http.Client().send(request).timeout(const Duration(seconds: 30));
    final body = await response.stream.bytesToString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
          'Emby ${response.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}');
    }
    return body;
  }

  http.Request _request(String method, String url, [String? body]) {
    final r = http.Request(method, Uri.parse(url));
    r.headers.addAll(_headers);
    if (body != null) {
      r.headers['Content-Type'] = 'application/json';
      r.body = body;
    }
    return r;
  }

  Future<AuthResult> authenticate(String username, String password) async {
    final body = jsonEncode({'Username': username, 'Pw': password});
    final text =
        await _execute(_request('POST', '$base/Users/AuthenticateByName', body));
    final result =
        AuthResult.fromJson(jsonDecode(text) as Map<String, dynamic>);
    token = result.accessToken;
    userId = result.user.id;
    return result;
  }

  Future<List<EmbyItem>> _itemsFromUrl(String url) async {
    final text = await _execute(_request('GET', url));
    final j = jsonDecode(text) as Map<String, dynamic>;
    return (j['Items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(EmbyItem.fromJson)
            .toList() ??
        const <EmbyItem>[];
  }

  /// Runs an items query once per parent library (or once unscoped
  /// when [parentIds] is empty) and merges, de-duplicated by id.
  Future<List<EmbyItem>> _scopedItems(
    String Function(String? parentId) urlFor,
    List<String> parentIds,
  ) async {
    if (parentIds.isEmpty) return _itemsFromUrl(urlFor(null));
    final seen = <String>{};
    final out = <EmbyItem>[];
    for (final pid in parentIds) {
      for (final item in await _itemsFromUrl(urlFor(pid))) {
        if (seen.add(item.id)) out.add(item);
      }
    }
    return out;
  }

  /// Ids of the user's book libraries. Emby types an audiobook
  /// library "audiobooks" (distinct from the "books" ebook type);
  /// both count. Scoping the book lists to these libraries keeps
  /// music out even when the server types music items unexpectedly.
  Future<List<String>> bookLibraryIds() async {
    final ids = <String>{};
    bool isBookType(Object? ct) {
      final s = (ct as String?)?.toLowerCase();
      return s == 'books' || s == 'audiobooks';
    }

    // The library configuration is the authoritative source for
    // collection types (Views do not always carry them). This
    // endpoint may require elevated rights; failure just skips it.
    try {
      final text =
          await _execute(_request('GET', '$base/Library/VirtualFolders'));
      final folders = jsonDecode(text);
      if (folders is List) {
        for (final f in folders) {
          if (f is Map<String, dynamic> &&
              isBookType(f['CollectionType']) &&
              f['ItemId'] is String) {
            ids.add(f['ItemId'] as String);
          }
        }
      }
    } catch (_) {
      // Not fatal: the Views pass below still applies.
    }

    // Views: match on collection type, or on a library name that
    // says it holds audio books (e.g. "Audio books").
    try {
      final text =
          await _execute(_request('GET', '$base/Users/$userId/Views'));
      final j = jsonDecode(text) as Map<String, dynamic>;
      final items = (j['Items'] as List?) ?? const [];
      for (final v in items) {
        if (v is! Map<String, dynamic> || v['Id'] is! String) continue;
        final name = (v['Name'] as String? ?? '').toLowerCase();
        final nameSaysAudioBooks =
            name.contains('audio') && name.contains('book');
        if (isBookType(v['CollectionType']) || nameSaysAudioBooks) {
          ids.add(v['Id'] as String);
        }
      }
    } catch (_) {
      // Keep whatever VirtualFolders found.
    }
    return ids.toList();
  }

  /// Books with a saved position — the "currently playing" shelf.
  /// The book libraries the app scopes its shelves to, with their
  /// display names - shown in Settings so the filtering is visible
  /// rather than magic.
  Future<List<({String id, String name})>> bookLibraries() async {
    final ids = await bookLibraryIds();
    if (ids.isEmpty) return const [];
    final names = <String, String>{};
    try {
      final text =
          await _execute(_request('GET', '$base/Library/VirtualFolders'));
      final list = jsonDecode(text) as List<dynamic>;
      for (final v in list) {
        if (v is Map<String, dynamic>) {
          final id = v['ItemId'] as String?;
          final name = v['Name'] as String?;
          if (id != null && name != null) names[id] = name;
        }
      }
    } catch (_) {
      // Names are a nicety; fall through to the Views lookup.
    }
    try {
      final text = await _execute(_request('GET', '$base/Users/$userId/Views'));
      final j = jsonDecode(text) as Map<String, dynamic>;
      for (final v in (j['Items'] as List?) ?? const []) {
        if (v is Map<String, dynamic>) {
          final id = v['Id'] as String?;
          final name = v['Name'] as String?;
          if (id != null && name != null) names.putIfAbsent(id, () => name);
        }
      }
    } catch (_) {}
    return [for (final id in ids) (id: id, name: names[id] ?? 'Library')];
  }

  /// Every Audio item in the given libraries, with the fields the
  /// series logic needs (path, album, index). One request per
  /// library; his audiobooks library answers ~3.5k items in ~2s.
  Future<List<EmbyItem>> libraryAudioItems(List<String> parentIds) {
    return _scopedItems(
      (pid) => '$base/Users/$userId/Items?Recursive=true'
          '&IncludeItemTypes=Audio'
          '&Fields=Path,AlbumId,IndexNumber,PrimaryImageAspectRatio'
          '&EnableImages=true'
          '${pid == null ? '' : '&ParentId=$pid'}',
      parentIds,
    );
  }

  Future<List<EmbyItem>> resumeItems({
    List<String> parentIds = const [],
  }) async {
    final items = await _scopedItems(
      (pid) => '$base/Users/$userId/Items/Resume?Limit=24&Recursive=true'
          '&IncludeItemTypes=Audio&MediaTypes=Audio'
          '&Fields=PrimaryImageAspectRatio&EnableImages=true'
          '${pid == null ? '' : '&ParentId=$pid'}',
      parentIds,
    );
    // Emby's Resume endpoint also returns books that merely have user
    // data on file (e.g. every later book in a series the user has
    // touched), which made Continue Listening list whole series runs.
    // "Continue" means a saved position exists. The played flag must
    // NOT exclude an item: Emby's own Continue Listening keeps books
    // that carry its played checkmark as long as they have a position
    // (observed on device), and finished books drop out on their own
    // because marking them played resets their position to zero.
    return items.where((i) {
      final ud = i.userData;
      return ud != null && ud.playbackPositionTicks > 0;
    }).toList();
  }

  /// Every audiobook the user has favorited on the server.
  ///
  /// Verified against the real server (2026-11-19): this library
  /// contains NO AudioBook-typed items at all - books are plain
  /// Audio files, and a favorite is usually set on the book's
  /// MusicAlbum rather than on the file. (The AudioBook type filter
  /// used before silently mapped to Audio, which is why unscoped
  /// queries returned songs and scoped ones returned nothing.) So
  /// favorites = favorited files + favorited albums, library-scoped.
  Future<List<EmbyItem>> favoriteItems({
    List<String> parentIds = const [],
  }) async {
    String urlFor(String type, String? pid) =>
        '$base/Users/$userId/Items?Recursive=true&Filters=IsFavorite'
        '&IncludeItemTypes=$type'
        '&Fields=PrimaryImageAspectRatio&EnableImages=true'
        '&SortBy=SortName&SortOrder=Ascending'
        '${pid == null ? '' : '&ParentId=$pid'}';
    final audio =
        await _scopedItems((pid) => urlFor('Audio', pid), parentIds);
    final albums =
        await _scopedItems((pid) => urlFor('MusicAlbum', pid), parentIds);
    // Duration guard for files only: a favorited file shorter than
    // 15 minutes is a song, not a book. Albums need no guard - they
    // are library-scoped and carry the book's total runtime.
    const minBookTicks = 9000000000; // 15 min in 100ns ticks
    final files = audio.where((i) {
      final rt = i.runTimeTicks;
      return rt == null || rt >= minBookTicks;
    });
    return [...files, ...albums]..sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// The playable files of a MusicAlbum "book", in play order.
  Future<List<EmbyItem>> albumChildren(String albumId) async {
    final text = await _execute(_request(
        'GET',
        '$base/Users/$userId/Items?ParentId=$albumId'
        '&IncludeItemTypes=Audio&SortBy=IndexNumber,SortName'
        '&SortOrder=Ascending&Fields=PrimaryImageAspectRatio'));
    final j = jsonDecode(text) as Map<String, dynamic>;
    final items = (j['Items'] as List?) ?? const [];
    return [
      for (final v in items)
        if (v is Map<String, dynamic>) EmbyItem.fromJson(v),
    ];
  }

  Future<EmbyItem> itemDetails(String itemId) async {
    final text = await _execute(
        _request('GET', '$base/Users/$userId/Items/$itemId?Fields=Chapters'));
    return EmbyItem.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<PlaybackInfoResponse> playbackInfo(String itemId) async {
    final text = await _execute(
        _request('POST', '$base/Items/$itemId/PlaybackInfo?UserId=$userId', '{}'));
    return PlaybackInfoResponse.fromJson(
        jsonDecode(text) as Map<String, dynamic>);
  }

  /// Resolve a media source to an absolute, playable URL.
  String streamUrl(String itemId, MediaSourceDto source) {
    final rel = source.directStreamUrl ?? source.transcodingUrl;
    if (rel != null) {
      return rel.startsWith('http') ? rel : base + rel;
    }
    final container = source.container ?? 'mp3';
    return '$base/Audio/$itemId/stream.$container?Static=true&api_key=$token';
  }

  String imageUrl(String itemId) => '$base/Items/$itemId/Images/Primary?api_key=$token';

  // ---- Playback session reporting: this is what keeps the position
  // ---- synced in Emby (and therefore in every other Emby client).

  Future<void> _report(String path, String itemId, String playSessionId,
      int positionTicks, bool isPaused) async {
    final body = jsonEncode({
      'ItemId': itemId,
      'PlaySessionId': playSessionId,
      'PositionTicks': positionTicks,
      'PlayMethod': 'DirectStream',
      'CanSeek': true,
      'IsPaused': isPaused,
    });
    try {
      await _execute(_request('POST', '$base$path', body));
    } catch (_) {
      // Reporting must never break playback.
    }
  }

  Future<void> reportPlaying(
          String itemId, String playSessionId, int positionTicks) =>
      _report('/Sessions/Playing', itemId, playSessionId, positionTicks, false);

  Future<void> reportProgress(String itemId, String playSessionId,
          int positionTicks, bool isPaused) =>
      _report('/Sessions/Playing/Progress', itemId, playSessionId,
          positionTicks, isPaused);

  Future<void> reportStopped(
          String itemId, String playSessionId, int positionTicks) =>
      _report('/Sessions/Playing/Stopped', itemId, playSessionId,
          positionTicks, true);

  static const int ticksPerMs = 10000;
  static int msToTicks(int ms) => ms * ticksPerMs;
  static int ticksToMs(int ticks) => ticks ~/ ticksPerMs;
}
