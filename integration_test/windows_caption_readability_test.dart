import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import '../test/streaming_audio_test.dart' show StreamPlatform, StreamSession;
import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native subtitles retain late finals, roll long speech and clear on stop',
    (tester) async {
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      final folder = await Directory.systemTemp.createTemp(
        'echopane-readability-',
      );
      late StreamSession stream;
      final streams = <StreamSession>[];
      await app.startApplication(
        audioPlatform: StreamPlatform(),
        audioStreamFactory: () async {
          stream = StreamSession();
          streams.add(stream);
          return stream;
        },
        settingsStore: MemorySettings(),
        credentials: MemoryCredentials()..key = 'fixture',
        overlaySettingsStore: FileOverlaySettingsStore(
          path: '${folder.path}/overlay.json',
        ),
        screenOverlaySettingsStore: FileScreenOverlaySettingsStore(
          path: '${folder.path}/screen.json',
        ),
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final audio = window.audio!, overlay = window.overlay!;
      const native = WindowsOverlayPlatform.channel;
      List<String> displayed() =>
          overlay.displayRows.map((r) => r.text).toList();
      Future<void> wait(Duration duration) async {
        final clock = Stopwatch()..start();
        while (clock.elapsed < duration) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
        }
      }

      Future<void> emit(SpeechUpdate update) async {
        stream.controller.add(update);
        await wait(const Duration(milliseconds: 150));
      }

      Future<void> screenshot(String name) async {
        if (artifacts.isEmpty) return;
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
        await File('$artifacts/$name.png')
            .writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      }

      try {
        window.captions!.select(RecognitionMode.audio);
        window.translation!.setEnabled(true);
        await audio.selectBackend(AudioBackend.cloud);
        await audio.start();
        await overlay.show(true, restore: true);
        await native.invokeMethod<Object?>('debugMove', {
          'x': 60,
          'y': 60,
          'width': 960,
          'height': 330,
        });
        await windowManager.hide();
        await emit(
          const SpeechUpdate(
            id: '1',
            source: 'The first sentence.',
            translation: '第一句的临时译文',
          ),
        );
        await emit(
          const SpeechUpdate(
            id: '2',
            source: 'The second sentence.',
            translation: '正在翻译下一句',
          ),
        );
        await emit(
          const SpeechUpdate(
            id: '1',
            source: 'The first sentence.',
            translation: '第一句现在完整翻译出来了。',
            isFinal: true,
          ),
        );
        expect(displayed().join(), contains('第一句现在完整翻译出来了。'));
        expect(displayed().join(), contains('正在翻译下一句'));
        expect(audio.text, 'The second sentence.');
        expect(window.history!.length, 1);
        await screenshot('late-final');
        await wait(const Duration(milliseconds: 900));
        expect(displayed().join(), contains('第一句现在完整翻译出来了。'));
        await audio.stop();
        expect(overlay.displayRows, isEmpty);
        await audio.start();
        await overlay.save(
          const OverlaySettings(mode: SubtitleMode.translated, maxLines: 2),
        );
        await native.invokeMethod<Object?>('debugMove', {
          'x': 60,
          'y': 60,
          'width': 540,
          'height': 220,
        });
        const long =
            '第一部分我们沿着这条道路前进沿途可以看到许多树木和房屋接着我们会穿过广场'
            '到达目的地请大家留意身边的变化同时注意交通安全最后这就是结尾';
        await emit(
          const SpeechUpdate(
            id: 'long',
            source: 'Continuous speech without a pause.',
            translation: long,
          ),
        );
        final first = displayed();
        expect(audio.running, true, reason: audio.error);
        expect(first, isNotEmpty);
        expect(first.length, lessThanOrEqualTo(2));
        expect(first.join(), isNot(contains('…')));
        await screenshot('long-start');
        await wait(const Duration(milliseconds: 4300));
        expect(displayed(), isNot(equals(first)));
        expect(displayed().join(), isNot(contains('…')));
        await screenshot('long-rolled');
        await audio.stop();
        expect(overlay.displayRows, isEmpty);
        await wait(const Duration(seconds: 1));
        expect(overlay.displayRows, isEmpty);
        await overlay.close();
        expect(tester.takeException(), isNull);
      } finally {
        await audio.stop();
        await overlay.close();
        await window.screenOverlay!.close();
        for (final session in streams) {
          await session.controller.close();
        }
        final prefix =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}echopane-readability-';
        if (folder.absolute.path.startsWith(prefix)) {
          await tester.runAsync(() => folder.delete(recursive: true));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
