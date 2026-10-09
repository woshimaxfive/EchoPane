import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/subtitles/caption_stabilizer.dart';
import 'package:echopane/subtitles/overlay_renderer.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/subtitles/overlay_controller.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/capture/capture_controller.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/ocr/ocr_controller.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'capture_controller_test.dart' show FakePlatform;
import 'ocr_test.dart' show FakeOcr;
import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

class _IdleOverlay implements OverlayPlatform {
  final captureOptions = <bool>[];
  @override
  void listen(void Function(OverlayWindowState)? listener) {}
  @override
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool locked,
    bool restore = false,
    bool allowCapture = false,
    int? displayId,
  }) async {
    captureOptions.add(allowCapture);
    return OverlayWindowState(visible: visible, locked: locked);
  }

  @override
  Future<bool> present(int width, int height, Uint8List rgba) async => false;
}

class _MemoryStyles implements OverlaySettingsStore {
  OverlaySettings value = const OverlaySettings();
  bool failWrite = false;
  @override
  Future<OverlaySettings> read() async => value;
  @override
  Future<void> write(OverlaySettings settings) async {
    if (failWrite) throw StateError('Storage unavailable');
    value = settings;
  }
}

void main() {
  testWidgets(
    'failed remote setting save restores capture exclusion and retains mouse pass-through',
    (tester) async {
      final capture = CaptureController(FakePlatform());
      final models = OcrModelStore(directory: 'unused');
      final ocr = OcrController(capture, models, FakeOcr());
      final translation = TranslationController(
        ocr,
        FakeTranslations(),
        MemorySettings(),
        MemoryCredentials(),
      );
      final platform = _IdleOverlay();
      final store = _MemoryStyles();
      final overlay = OverlayController(ocr, translation, platform, store);
      try {
        await overlay.initialize();
        await overlay.show(true, locked: true);
        store.failWrite = true;
        await expectLater(
          overlay.save(overlay.settings.copyWith(allowCapture: true)),
          throwsStateError,
        );
        expect(platform.captureOptions, [false, true, false]);
        expect(overlay.settings.allowCapture, isFalse);
        expect(store.value.allowCapture, isFalse);
        expect(overlay.window.locked, isTrue);
        expect(overlay.busy, isFalse);
        await overlay.close();
        await tester.pumpAndSettle();
      } finally {
        overlay.dispose();
        translation.dispose();
        ocr.dispose();
        models.dispose();
        capture.dispose();
      }
    },
  );
  test('overlay rejects mismatched translations and clears content when capture stops', () async {
    final capture = CaptureController(FakePlatform());
    final models = OcrModelStore(directory: 'unused');
    final ocr = OcrController(capture, models, FakeOcr());
    final translation = TranslationController(
      ocr,
      FakeTranslations(),
      MemorySettings(),
      MemoryCredentials(),
    );
    final overlay = OverlayController(
      ocr,
      translation,
      _IdleOverlay(),
      _MemoryStyles(),
    );
    try {
      await capture.initialize();
      await capture.start();
      ocr.lines = [const OcrLine('New sentence', 0.95)];
      translation.enabled = true;
      translation.originals = ['Old sentence'];
      translation.translations = ['旧译文'];
      expect(overlay.originals, ['New sentence']);
      expect(overlay.translations, isEmpty);
      translation.originals = ['New sentence'];
      translation.translations = ['新译文'];
      expect(overlay.translations, ['新译文']);
      await capture.stop();
      expect(overlay.originals, isEmpty);
      expect(overlay.translations, isEmpty);
    } finally {
      overlay.dispose();
      translation.dispose();
      ocr.dispose();
      models.dispose();
      capture.dispose();
    }
  });
  testWidgets(
    'brief OCR errors and blanks do not replace an established caption',
    (tester) async {
      final output = <List<String>>[];
      final stable = CaptionStabilizer<String>(output.add);
      stable.submit(['The road is still open.'], 'correct');
      await tester.pump(const Duration(milliseconds: 120));
      expect(output.single, ['The road is still open.']);
      stable.submit(['The roqd is still open.'], 'wrong');
      await tester.pump(const Duration(milliseconds: 400));
      stable.submit(['The road is still open.'], 'correct');
      await tester.pump(const Duration(milliseconds: 800));
      expect(output, hasLength(1));
      stable.submit([], 'blank');
      await tester.pump(const Duration(milliseconds: 400));
      stable.submit(['The road is still open.'], 'correct');
      await tester.pump(const Duration(milliseconds: 800));
      expect(output, hasLength(1));
      stable.submit(['明日の朝、ここで会いましょう。'], 'new');
      await tester.pump(const Duration(milliseconds: 499));
      expect(output, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(output.last, ['明日の朝、ここで会いましょう。']);
      stable.submit([], 'blank');
      await tester.pump(const Duration(milliseconds: 700));
      expect(output.last, isEmpty);
      stable.dispose();
    },
  );
  testWidgets(
    'continuous changes have bounded wait and stop cancels pending text',
    (tester) async {
      final output = <List<String>>[];
      final stable = CaptionStabilizer<String>(output.add);
      stable.submit(['First'], 'first');
      await tester.pump(const Duration(milliseconds: 120));
      for (int i = 0; i < 4; i++) {
        stable.submit(['Subtitle $i'], '$i');
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(output.last, ['Subtitle 3']);
      expect(output, hasLength(2));
      stable.submit(['Never publish after stop'], 'late');
      stable.reset();
      await tester.pump(const Duration(seconds: 2));
      expect(output, hasLength(2));
      stable.submit(['New session'], 'new-session');
      await tester.pump(const Duration(milliseconds: 120));
      expect(output.last, ['New session']);
      stable.dispose();
    },
  );
  test('translation-only mode waits without leaking mismatched originals', () {
    expect(
      subtitleRows(const OverlaySettings(mode: SubtitleMode.translated), [
        '原文',
      ], []),
      isEmpty,
    );
    final rows = subtitleRows(
      const OverlaySettings(),
      ['Original A', 'Original B'],
      ['译文 A', '译文 B'],
    );
    expect(rows.map((row) => row.text), [
      'Original A',
      '译文 A',
      'Original B',
      '译文 B',
    ]);
    expect(rows.map((row) => row.secondary), [true, false, true, false]);
    expect(
      subtitleRows(
        const OverlaySettings(),
        ['Original A', 'Original B'],
        ['Incomplete'],
      ).map((row) => row.text),
      ['Original A', 'Original B'],
    );
  });
  test(
    'subtitle styles persist without text or runtime window state',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'echopane-subtitle-styles-',
      );
      final file = File('${directory.path}/subtitles.json');
      final store = FileOverlaySettingsStore(path: file.path);
      try {
        await store.write(const OverlaySettings());
        await store.write(
          const OverlaySettings(
            mode: SubtitleMode.original,
            fontSize: 32,
            backgroundOpacity: 0,
            maxLines: 6,
            allowCapture: true,
          ),
        );
        final read = await store.read();
        expect(read.mode, SubtitleMode.original);
        expect(read.fontSize, 32);
        expect(read.backgroundOpacity, 0);
        expect(read.allowCapture, isTrue);
        final value =
            jsonDecode(await file.readAsString(encoding: utf8)) as Map;
        expect(
          value.keys,
          unorderedEquals([
            'version',
            'mode',
            'fontSize',
            'backgroundOpacity',
            'maxLines',
            'allowCapture',
          ]),
        );
        final legacy = Map<String, dynamic>.from(value)..remove('allowCapture');
        expect(OverlaySettings.fromJson(legacy).allowCapture, isFalse);
        expect((await file.readAsBytes()).take(3), isNot([239, 187, 191]));
        await file.writeAsString('{"mode":"bad"}', encoding: utf8);
        await expectLater(store.read(), throwsA(anything));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'transparent subtitle rendering retains readable opaque text at high DPI',
    (tester) async {
      final image = await tester.runAsync(
        () => renderSubtitles(
          width: 1440,
          height: 440,
          scale: 2,
          settings: const OverlaySettings(backgroundOpacity: 0),
          rows: const [SubtitleRow('明日の朝、ここで会いましょう。')],
          locked: true,
          status: '',
        ),
      );
      expect(image, isNotNull);
      final data = await tester.runAsync(
        () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      final bytes = data!.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      expect(bytes[3], 0);
      int brightPixels = 0;
      for (int i = 0; i < bytes.length; i += 4) {
        if (bytes[i] > 230 &&
            bytes[i + 1] > 230 &&
            bytes[i + 2] > 230 &&
            bytes[i + 3] > 250) {
          brightPixels++;
        }
      }
      expect(brightPixels, greaterThan(400));
      image!.dispose();
    },
  );
}
