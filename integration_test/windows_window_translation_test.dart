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
      throw StateError('Fixture credentials only');
  @override
  Future<void> delete() async {}
}

class _Request implements TranslationRequest {
  _Request(List<String> lines)
    : result = Future.value([
        for (final line in lines)
          line.contains('vacation') ? '问题19：说话者对那些不休假的人有什么看法？' : '其他内容',
      ]);
  @override
  final Future<List<String>> result;
  @override
  void cancel() {}
}

class _Provider implements TranslationProvider {
  int calls = 0;
  @override
  TranslationRequest translate(
    TranslationSettings settings,
    String key,
    List<String> lines,
  ) {
    calls++;
    return _Request(lines);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'window OCR preserves wrapped prose, avoids hiding and follows its target',
    (tester) async {
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      const supplied = String.fromEnvironment('SCREEN_FIXTURE_FILE');
      const width = 1392, height = 390;
      final folder = await Directory.systemTemp.createTemp(
        'echopane-window-test-',
      );
      String path = supplied;
      if (path.isEmpty) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)
          ..drawColor(const Color(0xff243344), BlendMode.src);
        final lines = [
          'Question 19. What does the speaker say about people not',
          'taking any vacation?',
        ];
        for (var i = 0; i < lines.length; i++) {
          final painter = TextPainter(
            text: TextSpan(
              text: lines[i],
              style: const TextStyle(
                fontSize: 40,
                color: Colors.white,
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 1320);
          painter.paint(
            canvas,
            Offset((width - painter.width) / 2, 106.0 + i * 64),
          );
          painter.dispose();
        }
        final picture = recorder.endRecording();
        final image = await picture.toImage(width, height);
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        path = '${folder.path}/question.rgba';
        await File(path).writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        image.dispose();
        picture.dispose();
      }
      final settings = FileSettingsStore(
        path: '${folder.path}/translation.json',
      );
      await settings.write(
        const TranslationSettings(
          baseUrl: 'http://127.0.0.1',
          model: 'fixture',
        ),
      );
      final provider = _Provider();
      await app.startApplication(
        settingsStore: settings,
        credentials: _Credentials(),
        translationProvider: provider,
        screenOverlaySettingsStore: FileScreenOverlaySettingsStore(
          path: '${folder.path}/screen.json',
        ),
      );
      await tester.pumpAndSettle();
      final view = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final capture = view.controller,
          ocr = view.ocr!,
          translation = view.translation!,
          overlay = view.screenOverlay!;
      const native = WindowsCapturePlatform.channel,
          screen = WindowsScreenOverlayPlatform.channel;
      Future<Map<Object?, Object?>> overlayState() async =>
          await screen.invokeMapMethod<Object?, Object?>('state') ?? {};
      Future<void> waitFor(Future<bool> Function() condition) async {
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
          if (await condition()) return;
        }
        fail(
          'Window pipeline failed: ${capture.error}, ${ocr.error}, ${overlay.error}; source=${ocr.text}',
        );
      }

      Future<void> screenshot(String name) async {
        if (artifacts.isEmpty) return;
        final frame = (await screen.invokeMapMethod<Object?, Object?>(
          'debugScreenshot',
        ))!;
        final buffer = await ui.ImmutableBuffer.fromUint8List(
          Uint8List.fromList((frame['rgba'] as List).cast<int>()),
        );
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: frame['width'] as int,
          height: frame['height'] as int,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final codec = await descriptor.instantiateCodec();
        final image = (await codec.getNextFrame()).image;
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$artifacts/$name.png').writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        image.dispose();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }

      try {
        await native.invokeMethod<Object?>('debugCreateFixture', {
          'path': path,
          'width': width,
          'height': height,
        });
        final target = CaptureTargetWindow.fromMap(
          (await native.invokeMapMethod<Object?, Object?>(
            'debugFixtureWindow',
          ))!,
        );
        await capture.chooseWindow(target);
        capture.region = const CaptureRegion(0, 100, width, 124);
        await waitFor(() async => ocr.ready);
        translation.setEnabled(true);
        overlay.setEnabled(true);
        await capture.start();
        await waitFor(
          () async => overlay.visible && translation.translations.length == 1,
        );
        expect(
          translation.originals.single,
          contains('people not taking any vacation'),
        );
        expect(translation.translations.single, contains('说话者'));
        final before = await overlayState();
        expect(before['excluded'], false);
        expect(before['transparent'], true);
        expect(
          before['y'] as int,
          greaterThanOrEqualTo(
            capture.outputDisplay!.y +
                capture.outputRegion!.y +
                capture.outputRegion!.height,
          ),
        );
        await screenshot('question-below');
        // The same tight crop also avoids hiding in monitor mode because the
        // compact translation window is entirely below the sampled pixels.
        final screenCrop = capture.outputRegion!;
        await capture.chooseDisplay(capture.outputDisplay!);
        capture.region = screenCrop;
        await capture.start();
        await waitFor(
          () async => overlay.visible && translation.translations.length == 1,
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
          expect(
            (await native.invokeMapMethod<Object?, Object?>(
              'snapshot',
            ))!['remoteSamples'],
            0,
          );
        }
        await capture.chooseWindow(target);
        capture.region = const CaptureRegion(0, 100, width, 124);
        await capture.start();
        await waitFor(
          () async => overlay.visible && translation.translations.length == 1,
        );
        final calls = provider.calls;
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
          expect(overlay.visible, true);
          expect(
            (await native.invokeMapMethod<Object?, Object?>(
              'snapshot',
            ))!['remoteSamples'],
            0,
          );
        }
        expect(provider.calls, calls);
        await native.invokeMethod<Object?>('debugMoveFixture', {
          'dx': 80,
          'dy': 20,
        });
        await waitFor(
          () async => (await overlayState())['x'] == (before['x'] as int) + 80,
        );
        expect((await overlayState())['y'], (before['y'] as int) + 20);
        expect(
          provider.calls,
          calls,
          reason: 'Moving unchanged text must not call translation again',
        );
        await overlay.save(
          overlay.settings.copyWith(mode: ScreenTranslationMode.replace),
        );
        await waitFor(
          () async => (await overlayState())['y'] != (before['y'] as int) + 20,
        );
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
          expect(ocr.text, contains('vacation'));
          expect(ocr.text, isNot(contains('说话者')));
          expect(
            (await native.invokeMapMethod<Object?, Object?>(
              'snapshot',
            ))!['remoteSamples'],
            0,
          );
        }
        await screenshot('question-replace');
        await native.invokeMethod<Object?>('debugMoveFixture', {
          'dx': 0,
          'dy': 0,
          'resize': true,
        });
        await waitFor(() async => capture.error?.contains('尺寸') == true);
        expect(overlay.visible, false);
        await capture.chooseWindow(target);
        capture.region = const CaptureRegion(0, 100, width, 124);
        await capture.start();
        await waitFor(() async => capture.snapshot?.frames != null);
        await native.invokeMethod<Object?>('debugDestroyFixture');
        await waitFor(() async => capture.error != null);
        expect(overlay.visible, false);
        await windowManager.setSize(const Size(680, 520));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (artifacts.isNotEmpty) {
          await File('$artifacts/window-results.json').writeAsString(
            jsonEncode({
              'windowCapture': true,
              'remoteSamples': 0,
              'tightScreenCropRemoteSamples': 0,
              'wrappedQuestionComplete': true,
              'moveWithoutRetranslation': true,
              'resizeAndCloseStop': true,
              'providerCalls': provider.calls,
              'scope': 'Real Windows WGC and OCR; injected Chinese translation; UU viewing and natural video remain unverified',
            }),
            encoding: utf8,
          );
        }
      } finally {
        await overlay.close();
        await capture.stop();
        await native.invokeMethod<Object?>('debugDestroyFixture');
        await windowManager.setSize(const Size(900, 720));
        await folder.delete(recursive: true);
      }
    },
  );
}
