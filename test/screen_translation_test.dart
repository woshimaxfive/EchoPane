import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/capture/capture_controller.dart';
import 'package:echopane/capture/capture_platform.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/ocr/ocr_controller.dart';
import 'package:echopane/screen_translation/screen_controller.dart';
import 'package:echopane/screen_translation/screen_platform.dart';
import 'package:echopane/screen_translation/screen_renderer.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:echopane/translation/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'capture_controller_test.dart' show FakePlatform;
import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

class _MovingOcr implements OcrPlatform {
  String text = 'Hello';
  int x = 30;
  @override
  Future<void> load(String directory) async {}
  @override
  Future<Map<Object?, Object?>> snapshot() async => {
    'ready': true,
    'width': 320,
    'height': 180,
    'lines': [
      {
        'text': text,
        'confidence': 0.95,
        'x': x,
        'y': 20,
        'width': 150,
        'height': 30,
        'background': 0xff123456,
      },
    ],
  };
}

class _ScreenPlatform implements ScreenOverlayPlatform {
  bool visible = false;
  int frames = 0;
  Completer<bool>? pending;
  @override
  void listen(void Function(OverlayWindowState)? listener) {}
  @override
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool allowCapture,
    required int displayId,
    CaptureRegion? region,
  }) async {
    this.visible = visible;
    return OverlayWindowState(
      visible: visible,
      locked: true,
      width: 320,
      height: 180,
    );
  }

  @override
  Future<bool> present(int width, int height, Uint8List rgba) async {
    frames++;
    return pending == null ? true : pending!.future;
  }
}

class _Styles implements ScreenOverlaySettingsStore {
  @override
  Future<ScreenOverlaySettings> read() async => const ScreenOverlaySettings();
  @override
  Future<void> write(ScreenOverlaySettings settings) async {}
}

void main() {
  test(
    'below mode handles capture regions narrower than its preferred width',
    () {
      final blocks = layoutScreenTranslations(
        size: const ui.Size(40, 100),
        lines: [
          const OcrLine('Hi', 1, bounds: ui.Rect.fromLTWH(5, 10, 30, 20)),
        ],
        translations: ['你好'],
        mode: ScreenTranslationMode.below,
      );
      expect(blocks.single.bounds.width, 40);
      expect(blocks.single.bounds.left, 0);
    },
  );

  test('below mode preserves originals and skips positions without room', () {
    final lines = [
      const OcrLine('one', 1, bounds: ui.Rect.fromLTWH(20, 20, 100, 30)),
      const OcrLine('two', 1, bounds: ui.Rect.fromLTWH(20, 55, 100, 30)),
      const OcrLine('edge', 1, bounds: ui.Rect.fromLTWH(20, 160, 100, 20)),
    ];
    final blocks = layoutScreenTranslations(
      size: const ui.Size(320, 180),
      lines: lines,
      translations: ['第一行', '第二行', '末行'],
      mode: ScreenTranslationMode.below,
    );
    expect(blocks.map((block) => block.text), ['第二行']);
    expect(blocks.single.bounds.top, greaterThan(lines[1].bounds.bottom));
    expect(
      lines.every((line) => !line.bounds.overlaps(blocks.single.bounds)),
      isTrue,
    );
  });

  test('replacement clips to capture pixels without applying monitor DPI', () {
    final blocks = layoutScreenTranslations(
      size: const ui.Size(320, 180),
      lines: [
        const OcrLine(
          'edge',
          1,
          bounds: ui.Rect.fromLTWH(300, 150, 50, 40),
          background: 0xff123456,
        ),
      ],
      translations: ['边缘'],
      mode: ScreenTranslationMode.replace,
    );
    expect(blocks.single.bounds, const ui.Rect.fromLTRB(298, 148, 320, 180));
    expect(blocks.single.background.toARGB32(), 0xff123456);
  });

  testWidgets(
    'renderer leaves unrelated pixels transparent and contains long text',
    (tester) async {
      await tester.runAsync(() async {
        final image = await renderScreenTranslations(
          width: 320,
          height: 180,
          blocks: [
            const PositionedTranslation(
              '很长的译文需要自动换行和缩小字号，而不能越过原文边界。',
              ui.Rect.fromLTWH(20, 30, 100, 40),
              30,
              ui.Color(0xff123456),
            ),
          ],
        );
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          expect(data.getUint8(3), 0);
          expect(data.getUint8((35 * 320 + 25) * 4 + 3), 255);
          expect(data.getUint8((75 * 320 + 125) * 4 + 3), 0);
        } finally {
          image.dispose();
        }
      });
    },
  );

  testWidgets(
    'moving text updates geometry without retranslating; stale and stopped frames disappear',
    (tester) async {
      await tester.runAsync(() async {
        final capture = CaptureController(FakePlatform());
        await capture.initialize();
        final models = OcrModelStore(directory: 'unused')
          ..phase = ModelPhase.ready;
        final native = _MovingOcr();
        final ocr = OcrController(
          capture,
          models,
          native,
          firstDelay: Duration.zero,
        );
        final captions = CaptionRouter(ocr, ocr);
        final provider = FakeTranslations();
        final store = MemorySettings()
          ..value = const TranslationSettings(
            baseUrl: 'http://127.0.0.1',
            model: 'fixture',
          );
        final translation = TranslationController(
          captions,
          provider,
          store,
          MemoryCredentials(),
          debounce: Duration.zero,
        );
        final platform = _ScreenPlatform();
        final overlay = ScreenOverlayController(
          ocr,
          captions,
          translation,
          platform,
          _Styles(),
        );
        Future<void> waitFor(bool Function() predicate) async {
          for (int i = 0; i < 100; i++) {
            if (predicate()) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('Screen overlay state did not settle');
        }

        try {
          await translation.initialize();
          await overlay.initialize();
          await capture.start();
          await ocr.poll();
          translation.setEnabled(true);
          overlay.setEnabled(true);
          await waitFor(() => provider.requests.isNotEmpty);
          provider.requests.single.completer.complete(['你好']);
          await waitFor(() => platform.frames == 1);
          native.x = 80;
          await ocr.poll();
          expect(ocr.spatialLines.single.bounds.left, 80);
          await waitFor(() => platform.frames == 2);
          expect(provider.requests.length, 1);
          native.text = 'Changed';
          await ocr.poll();
          await waitFor(() => !platform.visible);
          expect(translation.originals, [
            'Hello',
          ], reason: 'Stable text still awaits confirmation');
          await capture.stop();
          expect(ocr.spatialLines, isEmpty);
          expect(platform.visible, isFalse);
          await capture.start();
          await ocr.poll();
          await waitFor(() => provider.requests.length == 2);
          platform.pending = Completer<bool>();
          provider.requests.last.completer.complete(['改变了']);
          await waitFor(() => platform.frames == 3);
          await overlay.close();
          platform.pending!.complete(true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            platform.visible,
            isFalse,
            reason: 'A late presentation result must not reopen a dismissed overlay',
          );
        } finally {
          overlay.dispose();
          translation.dispose();
          captions.dispose();
          ocr.dispose();
          models.dispose();
          capture.dispose();
        }
      });
    },
  );
}
