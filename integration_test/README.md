# Windows integration tests

The independent subtitle suite uses the OCR fixtures with an injected translation fixture and isolated temporary settings. It opens a real layered window, checks presentation, capture exclusion while covering the input, interactive/transparent hit tests, recovery, resizing, minimized-main-window behavior, and minimum-size settings. The Debug screenshot method temporarily permits capture of this application's overlay over the owned fixture, with native screen capture stopped; it is excluded from Release builds. No production key or translation configuration is changed.

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

Create the result directory before running. Artifacts contain fixture text and a rendered application screenshot; use non-sensitive fixtures. This suite presents each image in a real Win32 window, captures it through the application's screen pipeline, then checks recognition updates, static-frame reuse, stopped-session results, and minimum window size. It also records timings and confidence values. Assertions cover selected text and lifecycle behavior; they do not establish general OCR accuracy or video performance. The app is moved over the fixture during the test to exercise self-window exclusion.
