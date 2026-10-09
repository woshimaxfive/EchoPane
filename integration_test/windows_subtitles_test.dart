import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/capture/capture_platform.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/translation/provider.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

class _NoCredentials implements CredentialStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String key) async =>
      throw StateError('No real credential writes');
  @override
  Future<void> delete() async {}
}

class _FixtureRequest implements TranslationRequest {
  _FixtureRequest(List<String> lines)
    : result = Future.value(
        lines
            .map(
              (text) => text.contains('sunrise')
                  ? '我们得在日出前离开。'
                  : text.contains('road')
                  ? '这条路仍然畅通。'
                  : '测试译文',
            )
            .toList(),
      );
  @override
  final Future<List<String>> result;
  @override
  void cancel() {}
}

class _FixtureTranslations implements TranslationProvider {
  int requests = 0;
  @override
  TranslationRequest translate(
    TranslationSettings settings,
    String key,
    List<String> lines,
  ) {
    requests++;
    return _FixtureRequest(lines);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'independent subtitles render, exclude capture, unlock and survive tray minimization',
    (tester) async {
      const manifest = String.fromEnvironment('ECHO_OCR_FIXTURES');
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      expect(manifest, isNotEmpty);
      final fixtures =
          jsonDecode(await File(manifest).readAsString(encoding: utf8)) as List;
      final fixture =
          fixtures.firstWhere((value) => value['name'] == 'english') as Map;
      final folder = await Directory.systemTemp.createTemp(
        'echopane-overlay-integration-',
      );
      final styles = FileOverlaySettingsStore(
        path: '${folder.path}/subtitles.json',
      );
      final settings = FileSettingsStore(
        path: '${folder.path}/translation.json',
      );
      final provider = _FixtureTranslations();
      await settings.write(
        const TranslationSettings(
          baseUrl: 'http://127.0.0.1',
          model: 'fixture',
        ),
      );
      await app.startApplication(
        settingsStore: settings,
        credentials: _NoCredentials(),
        translationProvider: provider,
        overlaySettingsStore: styles,
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final overlay = window.overlay!,
          capture = window.controller,
          ocr = window.ocr!,
          translation = window.translation!;
      const native = WindowsOverlayPlatform.channel;
      const screen = WindowsCapturePlatform.channel;
      Future<Map<Object?, Object?>> state() async =>
          await native.invokeMapMethod<Object?, Object?>('state') ?? {};
      Future<void> waitFrames(int previous) async {
        for (int i = 0; i < 100; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (((await state())['frames'] as int) > previous) return;
        }
        fail('Overlay did not present a frame');
      }

      try {
        expect(overlay.window.visible, isFalse);
        expect(overlay.window.locked, isFalse);
        final crop = await screen.invokeMapMethod<Object?, Object?>(
          'debugCreateFixture',
          {
            'path': fixture['path'],
            'width': fixture['width'],
            'height': fixture['height'],
          },
        );
        await capture.chooseDisplay(capture.displays.first);
        capture.region = CaptureRegion.fromMap(crop!);
        for (int i = 0; i < 100 && !ocr.ready; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
        }
        expect(ocr.ready, isTrue);
        await capture.start();
        translation.setEnabled(true);
        for (
          int i = 0;
          i < 120 && translation.phase != TranslationPhase.ready;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
        }
        expect(translation.translations, ['我们得在日出前离开。', '这条路仍然畅通。']);
        final baseline = await screen.invokeMapMethod<Object?, Object?>(
          'snapshot',
        );
        final baselinePixel = baseline!['centerPixel'] as List;
        await tester.tap(find.byKey(const Key('overlay-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('overlay-visible')));
        await tester.pumpAndSettle();
        await waitFrames(0);
        expect(overlay.window.visible, isTrue);
        final opened = await state();
        expect(opened['excluded'], isTrue);
        expect(opened['topmost'], isTrue);
        expect(await native.invokeMethod<int>('debugHitTest'), 2); // HTCAPTION
        expect(
          await native.invokeMethod<int>('debugHitTest', {'x': 2, 'y': 2}),
          13,
        ); // HTTOPLEFT
        await tester.tap(find.byKey(const Key('overlay-save')));
        await tester.pumpAndSettle();
        await overlay.save(
          const OverlaySettings(
            fontSize: 28,
            backgroundOpacity: 0.72,
            maxLines: 4,
          ),
        );
        expect((await styles.read()).fontSize, 28);
        final before = (await state())['frames'] as int;
        // The capture fixture is at monitor origin + (60, 60). Cover it with the overlay.
        final info = await native.invokeMapMethod<Object?, Object?>(
          'debugMove',
          {
            'x': 60,
            'y': 60,
            'width': 720,
            'height': 220,
            'displayId': capture.display!.id,
          },
        );
        await waitFrames(before);
        await windowManager.hide();
        await tester.pump(const Duration(milliseconds: 1500));
        await ocr.poll();
        expect(ocr.text, contains('sunrise'));
        expect(ocr.text, isNot(contains('随幕字幕')));
        expect(
          provider.requests,
          1,
          reason: 'Overlay is not fed back into OCR',
        );
        final captureEvidence = await screen.invokeMapMethod<Object?, Object?>(
          'snapshot',
        );
        final pixel = captureEvidence!['centerPixel'] as List;
        for (int i = 0; i < 3; i++) {
          expect(pixel[i] as int, closeTo(baselinePixel[i] as int, 2));
        }
        await overlay.show(true, locked: true);
        await tester.pump(const Duration(milliseconds: 300));
        expect(overlay.window.locked, isTrue);
        expect((await state())['transparent'], isTrue);
        expect(
          await native.invokeMethod<int>('debugHitTest'),
          -1,
        ); // HTTRANSPARENT
        await native.invokeMethod<Object?>('debugHotkey');
        await tester.pump(const Duration(milliseconds: 300));
        expect(overlay.window.locked, isFalse);
        expect((await state())['transparent'], isFalse);
        await overlay.show(true, locked: true);
        await overlay.show(true, restore: true);
        expect(overlay.window.locked, isFalse);
        expect(overlay.window.visible, isTrue);
        final resizeFrames = (await state())['frames'] as int;
        await native.invokeMethod<Object?>('debugMove', {
          'x': 60,
          'y': 60,
          'width': 960,
          'height': 320,
          'displayId': capture.display!.id,
        });
        await waitFrames(resizeFrames);
        expect(overlay.window.width, 960);
        expect(overlay.window.height, 320);
        expect(
          await native.invokeMethod<int>('debugHitTest', {'x': 958, 'y': 318}),
          17,
        ); // HTBOTTOMRIGHT
        await windowManager.show();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        expect(await windowManager.isVisible(), isTrue);
        await windowManager.minimize();
        for (int i = 0; i < 20 && await windowManager.isVisible(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(await windowManager.isVisible(), isFalse);
        expect((await state())['visible'], isTrue);
        await windowManager.restore();
        await windowManager.show();
        await overlay.save(
          const OverlaySettings(mode: SubtitleMode.translated),
        );
        expect(overlay.originals, hasLength(2));
        expect(overlay.translations, hasLength(2));
        await overlay.save(const OverlaySettings(backgroundOpacity: 0.95));
        await overlay.show(true, restore: true);
        final screenshotFrame = (await state())['frames'] as int;
        await native.invokeMethod<Object?>('debugMove', {
          'x': 60,
          'y': 60,
          'width': 720,
          'height': 220,
          'displayId': capture.display!.id,
        });
        await windowManager.hide();
        await waitFrames(screenshotFrame);
        // Stop native capture before the Debug-only desktop screenshot temporarily permits capture.
        await screen.invokeMethod<void>('stop');
        if (artifacts.isNotEmpty) {
          final sample = await native.invokeMapMethod<Object?, Object?>(
            'debugScreenshot',
          );
          final completer = Completer<ui.Image>();
          ui.decodeImageFromPixels(
            sample!['rgba'] as Uint8List,
            sample['width'] as int,
            sample['height'] as int,
            ui.PixelFormat.rgba8888,
            completer.complete,
          );
          final image = await completer.future;
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$artifacts/subtitle-overlay.png')
              .writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        }
        await capture.stop();
        await tester.pump(const Duration(milliseconds: 200));
        expect(overlay.originals, isEmpty);
        expect(overlay.translations, isEmpty);
        await native.invokeMethod<Object?>('debugClose');
        await tester.pump(const Duration(milliseconds: 100));
        expect(overlay.window.visible, isFalse);
        expect(capture.running, isFalse);
        await windowManager.restore();
        await windowManager.show();
        await windowManager.setSize(const Size(680, 520));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('overlay-settings')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        if (artifacts.isNotEmpty) {
          await File('$artifacts/subtitle-results.json').writeAsString(
            jsonEncode({
              'translation': 'Injected fixture, not a real provider',
              'captureExclusion': true,
              'topmost': true,
              'lockedHitTest': -1,
              'interactiveHitTest': 2,
              'hotkeyRegistered': opened['hotkey'],
              'hotkeyHandlerRecovery': true,
              'restoreRecovery': true,
              'trayMinimize': true,
              'minimumSize': '680x520',
              'renderSize': [info!['width'], info['height']],
              'stylePersistence': true,
              'translationCalls': provider.requests,
              'stopClearsText': true,
            }),
            encoding: utf8,
          );
        }
      } finally {
        await overlay.close();
        await capture.stop();
        translation.setEnabled(false);
        await screen.invokeMethod<void>('debugDestroyFixture');
        await windowManager.restore();
        await windowManager.show();
        await windowManager.setSize(const Size(900, 720));
        await folder.delete(recursive: true);
      }
    },
  );
}
