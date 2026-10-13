import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/capture/capture_platform.dart';
import 'package:echopane/screen_translation/screen_platform.dart';
import 'package:echopane/screen_translation/screen_renderer.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:echopane/translation/provider.dart';
import 'package:echopane/translation/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

class _Credentials implements CredentialStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String key) async =>
      throw StateError('No production credential writes');
  @override
  Future<void> delete() async {}
}

class _Request implements TranslationRequest {
  _Request(List<String> lines)
    : result = Future.value(
        lines
            .map(
              (line) => line.contains('sunrise')
                  ? '我们得在日出前离开。'
                  : line.contains('road')
                  ? '这条路仍然畅通。'
                  : line.contains('明日')
                  ? '明天早上我们在这里见面吧。'
                  : '一起开始新的旅程吧。',
            )
            .toList(),
      );
  @override
  final Future<List<String>> result;
  @override
  void cancel() {}
}

class _Provider implements TranslationProvider {
  int requests = 0;
  @override
  TranslationRequest translate(
    TranslationSettings settings,
    String key,
    List<String> lines,
  ) {
    requests++;
    return _Request(lines);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const soakSeconds = int.fromEnvironment('ECHO_SCREEN_SOAK_SECONDS');
  testWidgets(
    'screen translations align with OCR, remain capturable and never OCR themselves',
    (tester) async {
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      final folder = await Directory.systemTemp.createTemp(
        'echopane-screen-integration-',
      );
      // A page with enough room below both lines, unlike the tightly packed
      // subtitle fixture. Collision behavior is covered separately in unit tests.
      Future<Map<String, Object>> fixture(
        String name,
        List<String> lines, {
        double backgroundPhase = 0,
      }) async {
        const width = 1000, height = 400;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          Paint()
            ..shader =
                LinearGradient(
                  colors: [
                    Color.lerp(
                      const Color(0xff243344),
                      const Color(0xff384856),
                      backgroundPhase,
                    )!,
                    Color.lerp(
                      const Color(0xff4a657b),
                      const Color(0xff30495f),
                      backgroundPhase,
                    )!,
                  ],
                ).createShader(
                  Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
                ),
        );
        for (int i = 0; i < lines.length; i++) {
          final painter = TextPainter(
            text: TextSpan(
              text: lines[i],
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 850);
          painter.paint(canvas, Offset(100, 60.0 + i * 170));
          painter.dispose();
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(width, height);
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final file = File('${folder.path}/$name.rgba');
          await file.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
          return {'path': file.path, 'width': width, 'height': height};
        } finally {
          image.dispose();
          picture.dispose();
        }
      }

      final english = await fixture('english', [
        'We need to leave before sunrise.',
        'The road is still open.',
      ]);
      final japanese = await fixture('japanese', [
        '明日の朝、ここで会いましょう。',
        '新しい旅を始めましょう。',
      ]);
      final blank = await fixture('blank', []);
      final store = FileSettingsStore(path: '${folder.path}/translation.json');
      final styles = FileScreenOverlaySettingsStore(
        path: '${folder.path}/screen.json',
      );
      await store.write(
        const TranslationSettings(
          baseUrl: 'http://127.0.0.1',
          model: 'fixture',
        ),
      );
      final provider = _Provider();
      await app.startApplication(
        settingsStore: store,
        credentials: _Credentials(),
        translationProvider: provider,
        screenOverlaySettingsStore: styles,
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final capture = window.controller,
          ocr = window.ocr!,
          translation = window.translation!,
          overlay = window.screenOverlay!;
      const screen = WindowsCapturePlatform.channel;
      const native = WindowsScreenOverlayPlatform.channel;
      Future<Map<Object?, Object?>> state() async =>
          await native.invokeMapMethod<Object?, Object?>('state') ?? {};
      Future<void> waitFor(Future<bool> Function() predicate) async {
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
          if (await predicate()) return;
        }
        if (artifacts.isNotEmpty) {
          final value = (await screen.invokeMapMethod<Object?, Object?>(
            'debugCapturedFixture',
          ))!;
          final buffer = await ui.ImmutableBuffer.fromUint8List(
            value['rgba'] as Uint8List,
          );
          final descriptor = ui.ImageDescriptor.raw(
            buffer,
            width: value['width'] as int,
            height: value['height'] as int,
            pixelFormat: ui.PixelFormat.rgba8888,
          );
          final codec = await descriptor.instantiateCodec();
          final image = (await codec.getNextFrame()).image;
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('$artifacts/failed-input.png').writeAsBytes(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
          image.dispose();
          codec.dispose();
          descriptor.dispose();
          buffer.dispose();
        }
        final diagnostic = (await screen.invokeMapMethod<Object?, Object?>(
          'ocrSnapshot',
        ))!;
        diagnostic['lines'] = [
          for (final line in diagnostic['lines'] as List<Object?>? ?? [])
            Map<Object?, Object?>.of(line! as Map<Object?, Object?>)
              ..remove('patch'),
        ];
        fail(
          'Screen translation state did not settle: overlay=${overlay.error}, ocr=${ocr.error}, '
          'capture=${capture.phase}/${capture.error}, ready=${ocr.ready}, text=${ocr.text}, '
          'translation=${translation.enabled}/${translation.phase}/${translation.error}, native=$diagnostic',
        );
      }

      Future<void> screenshot(String name) async {
        if (artifacts.isEmpty) return;
        final value = (await native.invokeMapMethod<Object?, Object?>(
          'debugScreenshot',
        ))!;
        final rgba = value['rgba'] as List<int>;
        final buffer = await ui.ImmutableBuffer.fromUint8List(
          Uint8List.fromList(rgba),
        );
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: value['width'] as int,
          height: value['height'] as int,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        final image = (await codec.getNextFrame()).image;
        try {
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File('$artifacts/$name.png').writeAsBytes(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          );
        } finally {
          image.dispose();
          codec.dispose();
          descriptor.dispose();
          buffer.dispose();
        }
      }

      try {
        final crop = (await screen.invokeMapMethod<Object?, Object?>(
          'debugCreateFixture',
          {
            'path': english['path'],
            'width': english['width'],
            'height': english['height'],
          },
        ))!;
        await capture.chooseDisplay(capture.displays.first);
        capture.region = CaptureRegion.fromMap(crop);
        await waitFor(() async => ocr.ready);
        expect(find.byKey(const Key('overlay-settings')), findsNothing);
        expect(find.byKey(const Key('ocr-text')), findsNothing);
        await window.overlay!.show(true, restore: true);
        expect(window.overlay!.window.visible, isFalse);
        await tester.tap(find.byKey(const Key('capture-toggle')));
        await tester.pump();
        expect(overlay.enabled, isTrue);
        expect(translation.enabled, isTrue);
        await waitFor(() async => translation.translations.length == 2);
        expect(ocr.imageWidth, 1000);
        expect(ocr.imageHeight, 400);
        expect(
          ocr.spatialLines.every(
            (line) => line.bounds.width > 0 && line.bounds.height > 0,
          ),
          isTrue,
        );
        for (final line in [
          for (final block in ocr.spatialLines)
            ...block.sourceLines.isEmpty ? [block] : block.sourceLines,
        ]) {
          final patch = line.backgroundPatch!;
          int bright = 0, lowest = 255, highest = 0;
          for (int i = 0; i < patch.rgba.length; i += 4) {
            final red = patch.rgba[i];
            if (red < lowest) lowest = red;
            if (red > highest) highest = red;
            if (red > 220 &&
                patch.rgba[i + 1] > 220 &&
                patch.rgba[i + 2] > 220) {
              bright++;
            }
          }
          expect(
            bright / (patch.rgba.length / 4),
            lessThan(0.01),
            reason: 'Original white glyphs must be removed',
          );
          expect(
            highest - lowest,
            greaterThan(patch.bounds.width * (0x4a - 0x24) / 1000 * 0.5),
            reason: 'The repaired background must retain its gradient',
          );
        }
        await tester.tap(find.byKey(const Key('screen-overlay-settings')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('screen-overlay-save')));
        await tester.pumpAndSettle();
        await waitFor(() async => ((await state())['frames'] as int) > 0);
        expect(find.text('我们得在日出前离开。'), findsNothing);
        expect(window.overlay!.displayRows, isEmpty);
        final below = await state();
        expect(below['visible'], isTrue);
        expect(below['width'] as int, inInclusiveRange(1, 1000));
        expect(
          below['height'] as int,
          inInclusiveRange(1, capture.display!.height),
        );
        expect(below['excluded'], isFalse);
        expect(below['transparent'], isTrue);
        expect(await native.invokeMethod<int>('debugHitTest'), -1);
        await screenshot('screen-below');
        final frames = below['frames'] as int;
        await overlay.save(
          overlay.settings.copyWith(mode: ScreenTranslationMode.replace),
        );
        await waitFor(() async => ((await state())['frames'] as int) > frames);
        await screenshot('screen-replace');
        final calls = provider.requests;
        final sampleTimes = <int>[];
        for (int i = 0; i < 16; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          await ocr.poll();
          final sample = (await screen.invokeMapMethod<Object?, Object?>(
            'snapshot',
          ))!;
          sampleTimes.add(sample['remoteSampleMs'] as int);
          expect(ocr.text, contains('sunrise'));
          expect(ocr.text, isNot(contains('日出')));
        }
        expect(
          provider.requests,
          calls,
          reason: 'Own translations must not create new translation requests',
        );
        final captureState = (await screen.invokeMapMethod<Object?, Object?>(
          'snapshot',
        ))!;
        expect(captureState['sessionExclusion'], true);
        expect(captureState['remoteSamples'], 0);
        expect(
          captureState['exclusionUpdates'] as int,
          greaterThan(1),
          reason: 'The overlay was created after capture started',
        );
        expect(
          captureState['frameIteration'] as int,
          greaterThanOrEqualTo(captureState['exclusionIteration'] as int),
        );
        // WGC must still return the original pixels under the visible overlay,
        // rather than its Chinese translation or a black exclusion rectangle.
        final clean = (await screen.invokeMapMethod<Object?, Object?>(
          'debugCapturedFixture',
        ))!;
        final expected = await File(english['path'] as String).readAsBytes();
        final actual = clean['rgba'] as Uint8List;
        expect(actual.length, expected.length);
        int matching = 0;
        for (int i = 0; i < actual.length; i += 4) {
          if ((actual[i] - expected[i]).abs() <= 2 &&
              (actual[i + 1] - expected[i + 1]).abs() <= 2 &&
              (actual[i + 2] - expected[i + 2]).abs() <= 2) {
            matching++;
          }
        }
        expect(matching / (actual.length / 4), greaterThan(0.98));
        final soakSamples = <Map<String, Object?>>[];
        if (soakSeconds > 0) {
          final backgrounds = [english];
          for (var i = 1; i <= 3; i++) {
            backgrounds.add(
              await fixture('background$i', [
                'We need to leave before sunrise.',
                'The road is still open.',
              ], backgroundPhase: i / 3),
            );
          }
          final clock = Stopwatch()..start();
          final resourceClock = Stopwatch()..start();
          var updates = 0;
          var hidden = 0;
          var mode = ScreenTranslationMode.replace;
          while (clock.elapsed.inSeconds < soakSeconds) {
            final next = (clock.elapsed.inSeconds ~/ 15).isEven
                ? ScreenTranslationMode.below
                : ScreenTranslationMode.replace;
            if (next != mode) {
              mode = next;
              await overlay.save(overlay.settings.copyWith(mode: mode));
            }
            final background = backgrounds[updates++ % backgrounds.length];
            await screen.invokeMethod<void>('debugUpdateFixture', background);
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 500)),
            );
            await tester.pump(const Duration(milliseconds: 50));
            await ocr.poll();
            final captureSample = (await screen
                .invokeMapMethod<Object?, Object?>('snapshot'))!;
            final overlaySample = await state();
            if (overlaySample['visible'] != true) hidden++;
            expect(ocr.text, contains('sunrise'));
            expect(ocr.text, isNot(contains('日出')));
            expect(ocr.error, isNull);
            expect(overlay.error, isNull);
            expect(capture.running, true);
            expect(captureSample['sessionExclusion'], true);
            expect(captureSample['remoteSamples'], 0);
            if (resourceClock.elapsed.inSeconds >= 15 || soakSamples.isEmpty) {
              resourceClock.reset();
              soakSamples.add({
                'seconds': clock.elapsedMilliseconds / 1000,
                'mode': mode.name,
                'rssBytes': ProcessInfo.currentRss,
                'frames': captureSample['frames'],
                'overlayFrames': overlaySample['frames'],
                'providerRequests': provider.requests,
              });
            }
            expect(tester.takeException(), isNull);
          }
          expect(
            hidden,
            0,
            reason: 'Stable text over changing backgrounds must stay visible',
          );
          expect(
            provider.requests,
            calls,
            reason: 'Background changes must not retranslate unchanged text',
          );
          if (artifacts.isNotEmpty) {
            await File('$artifacts/screen-soak-results.json').writeAsString(
              jsonEncode({
                'seconds': clock.elapsedMilliseconds / 1000,
                'backgroundUpdates': updates,
                'invisibleSamples': hidden,
                'providerRequests': provider.requests,
                'samples': soakSamples,
                'scope': 'Owned changing gradient fixtures, real Windows capture/OCR/overlay, injected translations; not natural video or UU acceptance',
                'passed': true,
              }),
              encoding: utf8,
            );
          }
          await screen.invokeMethod<void>('debugUpdateFixture', english);
          await overlay.save(
            overlay.settings.copyWith(mode: ScreenTranslationMode.replace),
          );
          await waitFor(() async => overlay.visible);
        }
        await overlay.save(overlay.settings.copyWith(allowCapture: false));
        await waitFor(() async => (await state())['excluded'] == true);
        expect((await styles.read()).allowCapture, isFalse);
        await screen.invokeMethod<void>('debugUpdateFixture', {
          'path': japanese['path'],
          'width': japanese['width'],
          'height': japanese['height'],
        });
        await waitFor(
          () async =>
              translation.originals.join().contains('明日') &&
              translation.translations.length == 2 &&
              overlay.visible,
        );
        await screenshot('screen-japanese');
        await screen.invokeMethod<void>('debugUpdateFixture', {
          'path': blank['path'],
          'width': blank['width'],
          'height': blank['height'],
        });
        await waitFor(() async => (await state())['visible'] == false);
        await screen.invokeMethod<void>('debugUpdateFixture', {
          'path': english['path'],
          'width': english['width'],
          'height': english['height'],
        });
        await waitFor(() async => overlay.visible);
        await native.invokeMethod<Object?>('debugHotkey');
        await tester.pump(const Duration(milliseconds: 100));
        expect(overlay.enabled, isFalse);
        expect((await state())['visible'], isFalse);
        overlay.setEnabled(true);
        await waitFor(() async => overlay.visible);
        await capture.stop();
        await tester.pump(const Duration(milliseconds: 200));
        expect((await state())['visible'], isFalse);
        // Exercise the full monitor independently of the OCR crop. Only the
        // owned fixture is read back or saved; no desktop pixels are exported.
        await screen.invokeMethod<int>('start', {
          'displayId': capture.display!.id,
        });
        final marker = Uint8List(120 * 60 * 4);
        for (int i = 0; i < marker.length; i += 4) {
          marker[i] = 230;
          marker[i + 1] = 40;
          marker[i + 2] = 180;
          marker[i + 3] = 255;
        }
        await native.invokeMethod<Object?>('configure', {
          'visible': true,
          'allowCapture': true,
          'locked': true,
          'restore': false,
          'displayId': capture.display!.id,
          'region': const CaptureRegion(160, 140, 120, 60).toMap(),
        });
        await native.invokeMethod<bool>('frame', {
          'width': 120,
          'height': 60,
          'rgba': marker,
        });
        Map<Object?, Object?> fullState = {};
        for (int i = 0; i < 50; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          fullState = (await screen.invokeMapMethod<Object?, Object?>(
            'snapshot',
          ))!;
          if ((fullState['frames'] as int) > 1 &&
              (fullState['frameIteration'] as int) >=
                  (fullState['exclusionIteration'] as int)) {
            break;
          }
        }
        expect(fullState['sessionExclusion'], true);
        expect(fullState['width'], capture.display!.width);
        expect(fullState['height'], capture.display!.height);
        expect(fullState['remoteSamples'], 0);
        final monitorFixture = (await screen.invokeMapMethod<Object?, Object?>(
          'debugCapturedFixture',
        ))!;
        final monitorPixels = monitorFixture['rgba'] as Uint8List;
        expect(monitorPixels.length, expected.length);
        var monitorMatches = 0;
        for (int i = 0; i < monitorPixels.length; i += 4) {
          if ((monitorPixels[i] - expected[i]).abs() <= 2 &&
              (monitorPixels[i + 1] - expected[i + 1]).abs() <= 2 &&
              (monitorPixels[i + 2] - expected[i + 2]).abs() <= 2) {
            monitorMatches++;
          }
        }
        expect(monitorMatches / (monitorPixels.length / 4), greaterThan(0.98));
        final desktopMarker = (await native.invokeMapMethod<Object?, Object?>(
          'debugScreenshot',
        ))!;
        expect((desktopMarker['rgba'] as Uint8List).take(4), [
          230,
          40,
          180,
          255,
        ], reason: 'A normal desktop capture must still see the overlay');
        await native.invokeMethod<Object?>('configure', {'visible': false});
        await screen.invokeMethod<void>('stop');
        await windowManager.setSize(const Size(680, 520));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (artifacts.isNotEmpty) {
          await File('$artifacts/screen-results.json').writeAsString(
            jsonEncode({
              'dpi': below['dpi'],
              'bounds': {
                'x': below['x'],
                'y': below['y'],
                'width': below['width'],
                'height': below['height'],
              },
              'remoteSampleMs': sampleTimes,
              'sessionExclusion': captureState['sessionExclusion'],
              'hiddenSamples': captureState['remoteSamples'],
              'cropOriginalPixelShare': matching / (actual.length / 4),
              'monitorOriginalPixelShare':
                  monitorMatches / (monitorPixels.length / 4),
              'desktopOverlayVisible': true,
              'backgroundRepair': true,
              'providerRequests': provider.requests,
              'note': 'Owned English/Japanese fixtures and injected translations; not real-video, cloud-quality or UU acceptance',
            }),
            encoding: utf8,
          );
        }
      } finally {
        await overlay.close();
        await capture.stop();
        await screen.invokeMethod<void>('debugDestroyFixture');
        await windowManager.setSize(const Size(900, 720));
        await windowManager.show();
        await folder.delete(recursive: true);
      }
    },
    timeout: Timeout(Duration(seconds: soakSeconds + 180)),
  );
}
