# Emby Audiobook Player

A small, audiobook-only Android client for a self-hosted [Emby](https://emby.media) server.

Built because the Emby Android app stops/freezes playback whenever a notification arrives, and the third-party alternative's free trial ran out. This app does one job: play your audiobooks, with the transport controls a book needs, and keep your place synced with the server.

It is a **player, not a librarian**. Browsing, searching, library management and downloads stay in the Emby app; this app picks up whatever you're listening to and plays it well.

Built on Flutter (Dart) since v0.2.0. The earlier native Kotlin/Compose version (v0.1.x) is preserved in this repo's git history.

## What it shows

Three shelves, all scoped to your Emby libraries of type "audiobooks":

- **Continue Listening** — books with a saved position on the server. Tapping one resumes playing immediately.
- **Next Up in Series** — the next unstarted book in each series you've begun (see "How series work" below).
- **Favorites** — audiobooks you've favorited in Emby. Tapping one opens it cued at its saved position, paused (a Settings toggle makes these shelves autoplay instead).

No music, no video, no general library browsing. The shelves refresh themselves when the app returns to the foreground, so a book you favorite or start in the Emby app is simply there when you switch back.

## How audiobooks are picked

This is reverse-engineered from a real server (verified 2026-11, Emby 4.10) and is the part most likely to differ on other servers:

- The audiobooks library contains **no `AudioBook`-typed items at all**. Books are plain `Audio` files (usually one Audible-style file per book), and Emby mirrors each book as a `MusicAlbum`. The app therefore queries `Audio` + `MusicAlbum`, never `AudioBook` (the server silently maps that filter to `Audio`, which is how songs leak in if you query unscoped).
- **Favorites live on the album, not the file.** A favorited *file* shorter than 15 minutes is treated as a song and skipped; albums are exempt from the duration guard.
- **Album covers live on the album's first file** — the album's own image endpoint returns 404 even though the album carries the cover's hash.
- **Continue Listening means a saved position > 0.** The played flag does *not* exclude a book (Emby keeps in-progress books that carry its played checkmark); finished books drop out on their own because marking played zeroes the position.
- There is deliberately **no unscoped fallback**: if no book library is detected, the shelves are honestly empty rather than filled with the wrong items.

### How series work

Emby stores no series field for audio items, so Next Up is computed from the two places series actually live:

- **Album series** — many books sharing one MusicAlbum, each carrying an `IndexNumber` (box sets). Only albums of long items (≥ 4 h each) count; chapter-split books, whose albums hold many short files, are excluded by that threshold.
- **Path series** — the Audible-style file name: `…: Series Name, Book 4 [ASIN].m4b`. Decimal numbers (3.5, 7.5) are supported.

"Next" is measured from the furthest book you've started; a candidate you're already partway through is never proposed. Where both routes name the same series, the file-name route wins (it usually covers more of the series).

## Player features

- Book-timeline player: a multi-file book plays as one book with a single seek bar; chapters from every file are merged onto the book timeline.
- Skip forward / back by a configurable number of seconds — in the player (tap the `-15s` / `+30s` captions to change them), in Settings, and honored by the notification buttons, headset keys and the home-screen widget alike.
- Next / previous chapter, next / previous track (previous restarts the chapter/track if you're more than 3 s in).
- Chapter list with jump-to.
- Playback speed 0.75×–2.0×, remembered per book.
- Sleep timer: 5–60 minutes, or end of chapter.
- **Resume rewind**: opening a book backs up a few seconds from the saved position (Settings: 0/10/20/30 s, default 20) so you re-hear the thread of the story.
- Time remaining on the player and on library rows.
- **Position sync**: progress is reported to Emby as you listen (on a 10 s timer, on pause, on seeks and track changes, and at the end), so every Emby client agrees on where you left off. Album books report per file, because that's where Emby keeps resume points.
- Background playback with system media notification and lock-screen controls (audio_service + just_audio).

### Audio focus: ducking, not freezing

The founding bug of the Emby app, fixed properly here: the audio session uses speech attributes with `gainTransientMayDuck` and `willPauseWhenDucked: false`, so a notification sound lowers the book's volume briefly instead of pausing it. (The stock `speech()` recipe requests full gain with pause-when-ducked — it sounds right for audiobooks and is exactly wrong.) A watchdog also recovers the rare stall where the player claims to be playing but the position no longer advances, nudging it with a pause/play (capped, so a genuinely dead stream isn't hammered forever).

## Home-screen widget

A compact 3 × 1 widget: cover, title, author, and rewind / play-pause / forward buttons.

- **Buttons act silently** — they're media keys sent to the playback service, using your configured skip lengths. Tapping the cover or title (anywhere that isn't a button) opens the app.
- **Play with nothing loaded continues your most recent book** at its server-saved position — even if the app was swiped away. The media key restarts the service and the playback handler picks the book up itself.
- The app is a single instance (`singleTask`): widget, notification and launcher all resume the same app rather than opening a second copy.

## Build & signing

- Flutter 3.50 (Dart 3.14): `flutter pub get`, then `flutter build apk --release`.
- CI (`.github/workflows/build.yml`) builds on every push to `main` and uploads the APK as a workflow artifact named **`EmbyAudiobookPlayer-v<version>.apk`**; pushing a `v*` tag additionally publishes a GitHub Release with the APK attached.
- **Signing is permanent**: release builds are signed with a keystore kept in the repo's GitHub secrets (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`) and restored by CI on every run, so updates install over the top of previous versions. (Before v0.3.0, builds were debug-signed by ephemeral CI runners and Android refused every over-install.) The keystore itself is never committed — this repo is public.
- The build step retries in-run: the Gradle plugin portal intermittently 404s Kotlin plugin artifacts on first request, and re-runs always succeeded.

### Cutting a release

1. Bump `version:` in `pubspec.yaml` (and the client `Version=` string in `lib/emby_api.dart` to match — it's what Emby shows as the client version).
2. Run `flutter analyze` (0 errors; a handful of info-level lints is the standing baseline).
3. Push to `main`; CI builds and uploads the artifact. Tag `v<version>` if you also want a GitHub Release.

## Known limitations & deliberate choices

- **HTTPS servers only, in practice**: the app doesn't enable Android cleartext traffic, so a plain-`http://` LAN server address will fail to connect. (The author's server is HTTPS; enabling cleartext is a security trade-off, not an oversight.)
- Continue Listening asks Emby for at most 24 resume entries and then applies the saved-position filter, so a server with many touched-but-unstarted books can show a shorter shelf than expected.
- A favorite album's progress bar divides the album's saved position (which Emby tracks per current file) by the album's total runtime, so it understates book progress. Opening the book itself always lands at the right place.
- Sign-in errors surface Emby's raw HTTP error text; a server address typed without a scheme gets `https://` prepended automatically.
- On-device crash capture: uncaught Dart errors are recorded to a file and shown on the next launch (there's no Play Console for a sideloaded app), so a screenshot of that screen is a complete bug report.

## Status

v0.4.9 — the widget behaves to spec (silent buttons, single app instance, continue-from-widget), shelves and series detection are verified against the author's real library (~3,500 books), and position sync, ducking and the stall watchdog are confirmed on device. A full code audit was done at v0.4.9; the bugs it found are fixed in that release.
