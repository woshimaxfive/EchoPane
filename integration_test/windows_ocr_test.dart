import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/capture/capture_platform.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'recognizes English and Japanese screen text and discards stopped work',
    (tester) async {
      const manifestPath = String.fromEnvironment('ECHO_OCR_FIXTURES');
      expect(
        manifestPath,
        isNotEmpty,
        reason: 'Provide local screen-text fixtures',
      );
      final fixtures = jsonDecode(
        await File(manifestPath).readAsString(encoding: utf8),
      ) as List;
      await app.main();
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final capture = window.controller;
      final ocr = window.ocr!;
      const channel = WindowsCapturePlatform.channel;
      for (int i = 0; i < 120 && !ocr.ready && ocr.error == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await ocr.poll();
      }
      expect(ocr.error, isNull);
      expect(ocr.ready, isTrue);
      final displays = capture.displays;
      final results = <Map<String, Object?>>[];
      try {
        for (final raw in fixtures) {
          final fixture = raw as Map<String, dynamic>;
          await capture.stop();
          final region = await channel.invokeMapMethod<Object?, Object?>(
            'debugCreateFixture',
            {
              'path': fixture['path'],
              'width': fixture['width'],
              'height': fixture['height'],
            },
          );
          await capture.chooseDisplay(displays.first);
          capture.region = CaptureRegion.fromMap(region!);
          await capture.start();
          final clock = Stopwatch()..start();
          for (
            int i = 0;
            i < 160 && ocr.recognized == 0 && ocr.error == null;
            i++
          ) {
            await tester.pump(const Duration(milliseconds: 100));
            await ocr.poll();
          }
          expect(ocr.error, isNull);
          if (ocr.recognized == 0) {
            debugPrint(
              'No OCR output: ${await channel.invokeMethod('ocrSnapshot')}; capture: ${await channel.invokeMethod('snapshot')}',
            );
          }
          expect(ocr.recognized, greaterThan(0));
          // Native inference completion precedes the buffered caption commit.
          for (int i = 0; i < 20 && ocr.stabilizing; i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await ocr.poll();
          }
          expect(ocr.stabilizing, isFalse);
          results.add({
            'name': fixture['name'],
            'text': ocr.text,
            'durationMs': ocr.durationMs,
            'screenToTextMs': clock.elapsedMilliseconds,
            'confidence': ocr.lines.map((line) => line.confidence).toList(),
          });
          if (fixture['name'] == 'english') {
            expect(ocr.text, contains('sunrise'));
            expect(ocr.text, contains('road'));
            final count = ocr.recognized;
            await tester.pump(const Duration(milliseconds: 1200));
            await ocr.poll();
            expect(
              ocr.recognized,
              count,
              reason: 'Unchanged images must skip inference',
            );
            final changed = fixtures.firstWhere(
              (value) => value['name'] == 'japanese',
            ) as Map;
            await channel.invokeMethod<void>('debugUpdateFixture', {
              'path': changed['path'],
              'width': changed['width'],
              'height': changed['height'],
            });
            for (int i = 0; i < 160 && !ocr.text.contains('明日'); i++) {
              await tester.pump(const Duration(milliseconds: 100));
              await ocr.poll();
            }
            expect(ocr.text, contains('明日'));
            expect(ocr.text, isNot(contains('sunrise')));
          }
          if (fixture['name'] == 'japanese') expect(ocr.text, contains('明日'));
          if (fixture['name'] == 'blank') expect(ocr.text, isEmpty);
          if (fixture['name'] == 'japanese') {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('window-content')),
            );
            await tester.pump();
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
            if (artifacts.isNotEmpty) {
              await File('$artifacts/ocr-window.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
            }
            image.dispose();
          }
          await ocr.poll();
          await capture.stop();
          await tester.pump(const Duration(milliseconds: 1000));
          await ocr.poll();
          expect(
            ocr.text,
            isEmpty,
            reason: 'Stopped OCR cannot publish old text',
          );
        }
        await windowManager.setSize(const Size(680, 520));
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          tester.takeException(),
          isNull,
          reason: 'Minimum idle size must fit',
        );
        await windowManager.setSize(const Size(900, 720));
      } finally {
        await capture.stop();
        await channel.invokeMethod<void>('debugDestroyFixture');
        const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
        if (artifacts.isNotEmpty) {
          await File('$artifacts/ocr-results.json')
              .writeAsString(jsonEncode(results), encoding: utf8);
        }
      }
    },
  );
}
