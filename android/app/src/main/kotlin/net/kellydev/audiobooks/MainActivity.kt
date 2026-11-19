package net.kellydev.audiobooks

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service requires the activity to be AudioServiceActivity so the
// background playback service shares the correct FlutterEngine. With a
// plain FlutterActivity, AudioService.init fails with "The Activity
// class declared in your AndroidManifest.xml is wrong or has not
// provided the correct FlutterEngine" (seen on device, v0.2.2).
class MainActivity : AudioServiceActivity()
