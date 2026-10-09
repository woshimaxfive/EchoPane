# Windows integration tests

The independent subtitle suite uses the OCR fixtures with an injected translation fixture and isolated temporary settings. It opens a real layered window, checks presentation, capture exclusion while covering the input, interactive/transparent hit tests, recovery, resizing, minimized-main-window behavior, and minimum-size settings. It also verifies capture visibility with mouse pass-through enabled, persistence of the remote option, and restoration of exclusion. The Debug screenshot method temporarily permits capture of this application's overlay over the owned fixture, with native screen capture stopped, then restores its previous capture policy; it is excluded from Release builds. No production key or translation configuration is changed.

```powershell
flutter test integration_test/windows_subtitles_test.dart -d windows --dart-define=ECHO_OCR_FIXTURES=C:/ocr-fixtures/manifest.json --dart-define=ECHO_TEST_ARTIFACTS=C:/ocr-fixtures/results
```

The tests require a Windows interactive desktop, Flutter's Windows build tools, and the native OCR dependencies described in the project README. Test-only native methods are excluded from Release builds.

Run capture regression:

```powershell
flutter test integration_test/windows_capture_test.dart -d windows
```

For OCR regression, first download models in the application. Supply a UTF-8 JSON array of local RGBA fixtures, where each pixel is four bytes in R, G, B, A order and each image has the declared dimensions. The suite expects fixtures named `english`, `japanese`, `small-english`, `blank`, `en-upstream`, and `japan-upstream`. Use horizontal English sentences containing “sunrise” and “road”, Japanese text containing “明日”, and a blank frame with no text. Images must be between 8×8 and 1920×1080 pixels. Paths must be absolute.

Example manifest entry:

```json
[
  {"name": "english", "path": "C:/ocr-fixtures/english.rgba", "width": 1000, "height": 240}
]
```

```powershell
flutter test integration_test/windows_ocr_test.dart -d windows --dart-define=ECHO_OCR_FIXTURES=C:/ocr-fixtures/manifest.json --dart-define=ECHO_TEST_ARTIFACTS=C:/ocr-fixtures/results
```

The translation integration suite uses the same English/Japanese fixtures and a local HTTP server. It uses a separate Debug-only Windows credential target; no real API key is needed or written to the production credential. It validates the protocol and display lifecycle, not real translation quality:

```powershell
flutter test integration_test/windows_translation_test.dart -d windows --dart-define=ECHO_OCR_FIXTURES=C:/ocr-fixtures/manifest.json --dart-define=ECHO_TEST_ARTIFACTS=C:/ocr-fixtures/results
```

Create the result directory before running. Artifacts contain fixture text and a rendered application screenshot; use non-sensitive fixtures. This suite presents each image in a real Win32 window, captures it through the application's screen pipeline, then checks recognition updates, static-frame reuse, stopped-session results, and minimum window size. It also records timings and confidence values. Assertions cover selected text and lifecycle behavior; they do not establish general OCR accuracy or video performance. The controls are placed below text fixtures to avoid capturing them. The capture regression separately verifies that the main window is capturable and that hiding it reveals the underlying fixture.

## Audio regression

The audio suite uses real multilingual Whisper inference and WASAPI loopback. It also injects a translation fixture to check source routing and bilingual overlay alignment; this does not validate a cloud service. Production credentials and settings are not modified. Install the speech models from the app first. Provide `en.f32` and `ja.f32`: little-endian float32 mono PCM at 16 kHz, amplitude within [-1, 1], maximum 30 seconds. Use non-sensitive speech samples with English “gold” and Japanese “中学”. The fixtures are not shipped by this repository; obtain appropriately licensed samples for local testing.

The suite audibly plays the English fixture on the default playback endpoint, then recognizes the device's actual loopback. Use a quiet desktop and an available speaker/headphone. It checks silent input, stop/start invalidation, simulated reroute/disconnect notifications, model language detection, subtitle reuse and minimum window size. Add `--dart-define=ECHO_VERIFY_AUDIO_DOWNLOAD=true` to verify real model downloads into an isolated temporary directory. Model timings and keywords do not establish general transcription accuracy or long-session performance.

```powershell
flutter test integration_test/windows_audio_test.dart -d windows --dart-define=ECHO_AUDIO_FIXTURES=C:/audio-fixtures --dart-define=ECHO_TEST_ARTIFACTS=C:/audio-fixtures/results
```
