import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

class _Translation implements TranslationRequest {
  _Translation(int length)
    : result = Future.value(List.filled(length, '音频测试译文'));
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
    return _Translation(lines.length);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local multilingual ASR and real playback loopback share subtitles', (
    tester,
  ) async {
    const fixtures = String.fromEnvironment('ECHO_AUDIO_FIXTURES');
    const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
    expect(fixtures, isNotEmpty);
    final folder = await Directory.systemTemp.createTemp(
      'echopane-audio-test-',
    );
    if (const bool.fromEnvironment('ECHO_VERIFY_AUDIO_DOWNLOAD')) {
      final downloads = OcrModelStore(
        directory: '${folder.path}/models',
        files: audioModelFiles,
      );
      await tester.runAsync(() async {
        await downloads.check();
        await downloads.download();
        expect(downloads.phase, ModelPhase.ready, reason: downloads.error);
        await downloads.check();
        expect(downloads.phase, ModelPhase.ready);
      });
      downloads.dispose();
    }
    final settings = MemorySettings()
      ..value = const TranslationSettings(
        baseUrl: 'http://127.0.0.1',
        model: 'fixture',
      );
    final provider = _Provider();
    await app.startApplication(
      settingsStore: settings,
      credentials: MemoryCredentials(),
      translationProvider: provider,
      overlaySettingsStore: FileOverlaySettingsStore(
        path: '${folder.path}/subtitles.json',
      ),
    );
    await tester.pumpAndSettle();
    final window = tester.widget<app.CaptureWindow>(
      find.byType(app.CaptureWindow),
    );
    final audio = window.audio!;
    window.captions!.select(RecognitionMode.audio);
    window.translation!.setEnabled(true);
    final results = <Map<String, Object?>>[];
    Future<void> until(bool Function() done, {int seconds = 180}) async {
      final clock = Stopwatch()..start();
      while (!done() && clock.elapsed.inSeconds < seconds) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await audio.poll();
        });
      }
      expect(
        done(),
        true,
        reason:
            'Audio timeout: ${audio.error}, running=${audio.running}, loading=${audio.starting}',
      );
    }

    try {
      await audio.start();
      await until(() => audio.running || audio.error != null);
      expect(audio.error, isNull);
      expect(audio.devices, isNotEmpty);
      for (final language in ['en', 'ja']) {
        final pcm = await tester.runAsync(
          () => File('$fixtures/$language.f32').readAsBytes(),
        );
        await WindowsAudioPlatform.channel.invokeMethod<void>('debugFixture', {
          'directory': audio.models.directory,
          'language': 'auto',
          'pcm': pcm,
        });
        await audio.poll();
        await until(
          () =>
              audio.durationMs > 0 &&
              audio.detectedLanguage == language &&
              audio.lines.isNotEmpty,
        );
        expect(audio.text, contains(language == 'en' ? 'gold' : '中学'));
        await until(() => window.translation!.translations.isNotEmpty);
        expect(window.translation!.originals, audio.lines);
        results.add({
          'kind': 'file',
          'language': language,
          'text': audio.text,
          'durationMs': audio.durationMs,
        });
        await audio.stop();
        expect(audio.lines, isEmpty);
        await audio.start();
        await until(() => audio.running);
      }
      // The fixture is rendered to the default speaker; recognition receives WASAPI loopback, not this buffer.
      final pcm = await tester.runAsync(
        () => File('$fixtures/en.f32').readAsBytes(),
      );
      await WindowsAudioPlatform.channel.invokeMethod<void>('debugPlay', {
        'pcm': pcm,
      });
      final heard = <String>{};
      await until(() {
        if (audio.text.isNotEmpty) heard.add(audio.text);
        return heard.any((value) => value.toLowerCase().contains('gold'));
      });
      expect(audio.samples, greaterThan(16000));
      expect(audio.dropped, 0);
      results.add({
        'kind': 'loopback',
        'language': audio.detectedLanguage,
        'texts': heard.toList(),
        'samples': audio.samples,
        'dropped': audio.dropped,
        'durationMs': audio.durationMs,
      });
      await window.overlay!.show(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(window.overlay!.originals, audio.lines);
      expect(window.overlay!.window.visible, true);
      expect(provider.calls, greaterThan(0));
      await until(() => window.overlay!.translations.isNotEmpty);
      expect(tester.takeException(), isNull);
      if (artifacts.isNotEmpty) {
        final boundary = tester.firstRenderObject(
          find.byKey(const Key('window-content')),
        ) as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$artifacts/audio-window.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }
      await audio.stop();
      await audio.poll();
      await tester.pump(const Duration(milliseconds: 500));
      expect(window.overlay!.originals, isEmpty);
      expect(audio.running, false);
      await audio.start();
      await until(() => audio.running);
      final previousSession = audio.captionSession;
      await WindowsAudioPlatform.channel.invokeMethod<void>('debugReroute');
      await until(() => audio.captionSession != previousSession);
      expect(audio.running, true);
      expect(audio.lines, isEmpty);
      await WindowsAudioPlatform.channel.invokeMethod<void>('debugDisconnect');
      await until(() => audio.error != null);
      expect(audio.running, false);
      expect(audio.lines, isEmpty);
      await audio.start();
      await until(() => audio.running);
      await WindowsAudioPlatform.channel.invokeMethod<void>('debugPlay', {
        'pcm': Uint8List(16000 * 4 * 3),
      });
      final quiet = Stopwatch()..start();
      while (quiet.elapsed.inSeconds < 4) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await audio.poll();
        });
        expect(audio.lines, isEmpty, reason: 'Silence must not produce text');
      }
      results.add({
        'kind': 'silence',
        'lines': audio.lines,
        'samples': audio.samples,
      });
      await windowManager.setSize(const Size(680, 520));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.takeException(),
        isNull,
        reason: 'Audio UI must fit the minimum size',
      );
      await audio.stop();
      await audio.start();
      await audio.stop();
      await tester.pump(const Duration(milliseconds: 500));
      await audio.poll();
      expect(audio.running, false);
      expect(audio.lines, isEmpty);
    } finally {
      await audio.stop();
      await window.overlay!.close();
      if (artifacts.isNotEmpty) {
        await File('$artifacts/audio-results.json')
            .writeAsString(jsonEncode(results), encoding: utf8);
      }
      final tempPrefix =
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}echopane-audio-test-';
      if (folder.absolute.path.startsWith(tempPrefix)) {
        await tester.runAsync(() => folder.delete(recursive: true));
      }
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
