# Emby Audiobook Player

A small, audiobook-only Android client for a self-hosted [Emby](https://emby.media) server.

Built because the Emby Android app stops/freezes playback whenever a notification arrives, and the third-party alternative's trial ran out. This app does one job: play your audiobooks, with the transport controls a book needs, and keep your place synced with the server.

**Since v0.2.0 the app is built on Flutter** (Dart). The earlier native Kotlin/Compose version (v0.1.x) is preserved in this repo's git history.

## Scope

Deliberately narrow — it shows only:

- **Continue Listening** — books with a saved position on your server
- **Favorites** — audiobooks you've favorited in Emby

No music, no video, no library browsing beyond those two lists.

## Features

- Sign in to your Emby server (token stored on-device only)
- Book-timeline player: multi-file books play as one book with a single seek bar
- Skip forward / back by a configurable number of seconds
- Next / previous chapter (from the chapter data Emby holds for the book)
- Next / previous track
- Playback speed (0.75×–2.0×)
- Position sync: progress is reported back to Emby as you listen, so every Emby client agrees on where you left off
- Background playback with system media / lock-screen controls (audio_service + just_audio)
- Audio focus that *ducks* under notification sounds instead of freezing (speech audio-session configuration)
- On-device crash capture: if the app dies, the next launch shows the recorded error instead of failing silently

## Build

- Flutter 3.50 (Dart 3.14): `flutter pub get` then `flutter build apk --release`
- Output: `build/app/outputs/flutter-apk/app-release.apk` (debug-key signed, sideloadable)
- CI builds the same APK on every push to `main` and uploads it as a workflow artifact; pushing a `v*` tag additionally publishes a GitHub Release with the APK attached.

## Status

v0.2.0 — the Flutter base. Same features and behaviour as the native v0.1.x line; expect the usual first-run rough edges, and use the crash screen if anything dies.
