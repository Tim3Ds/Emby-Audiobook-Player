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
  const UserDataDto({
    this.playbackPositionTicks = 0,
    this.playedPercentage,
    this.isFavorite = false,
    this.played = false,
  });
  factory UserDataDto.fromJson(Map<String, dynamic> j) => UserDataDto(
        playbackPositionTicks: (j['PlaybackPositionTicks'] as num?)?.toInt() ?? 0,
        playedPercentage: (j['PlayedPercentage'] as num?)?.toDouble(),
        isFavorite: j['IsFavorite'] as bool? ?? false,
        played: j['Played'] as bool? ?? false,
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

  /// Books with a saved position — the "currently playing" shelf.
  Future<List<EmbyItem>> resumeItems() async {
    final url = '$base/Users/$userId/Items/Resume?Limit=24&Recursive=true'
        '&IncludeItemTypes=AudioBook&MediaTypes=Audio'
        '&Fields=PrimaryImageAspectRatio&EnableImages=true';
    final text = await _execute(_request('GET', url));
    final j = jsonDecode(text) as Map<String, dynamic>;
    final items = (j['Items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(EmbyItem.fromJson)
            .toList() ??
        const <EmbyItem>[];
    // Emby's Resume endpoint also returns books that merely have user
    // data on file (e.g. every later book in a series the user has
    // touched), which made Continue Listening list whole series runs.
    // "Continue" means: a saved position exists and the book is not
    // finished — the same definition Emby's own apps show.
    return items.where((i) {
      final ud = i.userData;
      return ud != null && ud.playbackPositionTicks > 0 && !ud.played;
    }).toList();
  }

  /// Every audiobook the user has favorited on the server.
  Future<List<EmbyItem>> favoriteItems() async {
    final url = '$base/Users/$userId/Items?Recursive=true&Filters=IsFavorite'
        '&IncludeItemTypes=AudioBook&MediaTypes=Audio'
        '&Fields=PrimaryImageAspectRatio&EnableImages=true'
        '&SortBy=SortName&SortOrder=Ascending';
    final text = await _execute(_request('GET', url));
    final j = jsonDecode(text) as Map<String, dynamic>;
    return (j['Items'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(EmbyItem.fromJson)
            .toList() ??
        const [];
  }

  /// Full item details, including the chapter list when the server has one.
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
