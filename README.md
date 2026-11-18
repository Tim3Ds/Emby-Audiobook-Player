# Audiobooks for Emby

A small, audiobook-only Android client for a self-hosted [Emby](https://emby.media) server.

Built because the Emby Android app stops/freezes playback whenever a notification arrives, and the third-party alternative's trial ran out. This app does one job: play your audiobooks, with the transport controls a book needs, and keep your place synced with the server.

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
- Background playback with system media / lock-screen controls
- Audio focus that *ducks* under notification sounds instead of freezing

## Build

- JDK 17, Android SDK 34, Gradle 8.7 (AGP 8.5.2, Kotlin 2.0)
- `gradle :app:assembleDebug` → `app/build/outputs/apk/debug/app-debug.apk`
- Sideload the APK onto your phone (minSdk 26).

A Gradle wrapper will be added once the first build environment is settled.

## Status

v0.1.0 — first working slice. Not yet built/run against a live server; expect rough edges. Chapter buttons appear only when Emby has chapter data for the book.
