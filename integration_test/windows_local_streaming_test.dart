import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/capture/capture_platform.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:echopane/translation/provider.dart';
import 'package:echopane/translation/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

class _Request implements TranslationRequest {
  _Request(String text) : result = Future.value(['测试译文：$text']);
  @override
  final Future<List<String>> result;
  @override
  void cancel() {}
}

class _Provider implements TranslationProvider {
  final inputs = <String>[];
  @override
  TranslationRequest translate(
    TranslationSettings settings,
    String key,
    List<String> lines,
  ) {
    inputs.add(lines.single);
    return _Request(lines.single);
  }
}

class _PcmPlatform implements AudioPlatform, StreamingAudioPlatform {
  _PcmPlatform(this.pcm);
  final Uint8List pcm;
  final clock = Stopwatch();
  int session = 0, position = 0;
  bool running = false;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> start(String directory, String device, String language) =>
      startStream(device);
  @override
  Future<void> startStream(String device) async {
    session++;
    position = 0;
    running = true;
    clock
      ..reset()
      ..start();
  }

  @override
  Future<void> stop() async {
    running = false;
    clock.stop();
  }

  @override
  Future<Map<Object?, Object?>> snapshot() async {
    final end = clock.elapsedMilliseconds * 32 ~/ 2 * 2;
    final size = running ? end - position : 0;
    final data = Uint8List(size);
    if (size > 0 && position < pcm.length) {
      final count = size.clamp(0, pcm.length - position);
      data.setRange(0, count, pcm, position);
    }
    position = end;
    return {'running': running, 'session': session, 'dropped': 0, 'pcm': data};
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('controlled local PCM streams through real ASR alongside native OCR', (
    tester,
  ) async {
    const audioFixtures = String.fromEnvironment('ECHO_AUDIO_FIXTURES');
    const ocrFixtures = String.fromEnvironment('ECHO_OCR_FIXTURES');
    expect(audioFixtures, isNotEmpty);
    expect(ocrFixtures, isNotEmpty);
    final folder = await Directory.systemTemp.createTemp(
      'echopane-local-stream-',
    );
    final provider = _Provider();
    final wav = await File('$audioFixtures/en.wav').readAsBytes();
    expect(ascii.decode(wav.sublist(36, 40)), 'data');
    await app.startApplication(
      audioPlatform: _PcmPlatform(Uint8List.sublistView(wav, 44)),
      translationProvider: provider,
      settingsStore: MemorySettings(),
      credentials: MemoryCredentials()..key = 'fixture',
      overlaySettingsStore: FileOverlaySettingsStore(
        path: '${folder.path}/subtitles.json',
      ),
      screenOverlaySettingsStore: FileScreenOverlaySettingsStore(
        path: '${folder.path}/screen.json',
      ),
    );
    await tester.pumpAndSettle();
    final window = tester.widget<app.CaptureWindow>(
      find.byType(app.CaptureWindow),
    );
    final audio = window.audio!;
    final capture = window.controller;
    final ocr = window.ocr!;
    final translation = window.translation!;
    Future<void> until(bool Function() done) async {
      final clock = Stopwatch()..start();
      while (!done() && clock.elapsed.inSeconds < 18) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await audio.poll();
          await ocr.poll();
        });
      }
      expect(done(), true, reason: '${audio.error}; OCR: ${ocr.error}');
    }

    try {
      final fixtures = jsonDecode(
        await File(ocrFixtures).readAsString(encoding: utf8),
      ) as List;
      final fixture = fixtures.firstWhere((f) => f['name'] == 'english') as Map;
      final region = await WindowsCapturePlatform.channel
          .invokeMapMethod<Object?, Object?>('debugCreateFixture', {
            'path': fixture['path'],
            'width': fixture['width'],
            'height': fixture['height'],
          });
      await capture.chooseDisplay(capture.displays.first);
      capture.region = CaptureRegion.fromMap(region!);
      await capture.start();
      await until(() => ocr.text.contains('sunrise'));

      window.captions!.select(RecognitionMode.audio);
      window.history!.clear();
      await audio.selectBackend(AudioBackend.localStreaming);
      expect(audio.language, 'en');
      expect(audio.models.phase.name, 'ready');
      await tester.runAsync(audio.start);
      await until(() => audio.running);
      final clock = Stopwatch()..start();
      await until(() => audio.text.isNotEmpty);
      final firstTextMs = clock.elapsedMilliseconds;
      expect(audio.provisional, true);
      expect(window.history!.length, 0);
      expect(
        provider.inputs,
        isEmpty,
        reason: 'Offline original text requires no translation call',
      );
      translation.setEnabled(true);
      await until(() => provider.inputs.isNotEmpty);
      await until(() => window.history!.length == 1);
      await until(() => window.history!.entries.single.translations.isNotEmpty);
      expect(audio.text, contains('CHIEFTAIN'));
      expect(
        window.history!.entries.single.translations.single,
        contains('CHIEFTAIN'),
      );
      expect(audio.dropped, 0);

      // A real OCR revision runs while the ASR isolate is still listening.
      final japanese =
          fixtures.firstWhere((f) => f['name'] == 'japanese') as Map;
      await WindowsCapturePlatform.channel.invokeMethod<void>(
        'debugUpdateFixture',
        {
          'path': japanese['path'],
          'width': japanese['width'],
          'height': japanese['height'],
        },
      );
      await until(() => ocr.text.contains('明日'));
      expect(audio.running, true);
      translation.setEnabled(false);
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        audio.running,
        true,
        reason: 'Disabling translation must preserve offline recognition',
      );
      await window.overlay!.show(true);
      await tester.pump(const Duration(milliseconds: 300));
      expect(window.overlay!.displayRows.any((r) => r.text.isNotEmpty), true);
      await audio.stop();
      expect(window.history!.length, 1);

      // Native session IDs and isolate resources must survive repeated starts.
      for (var i = 0; i < 2; i++) {
        await tester.runAsync(audio.start);
        await until(() => audio.running);
        await tester.runAsync(audio.stop);
        expect(audio.lines, isEmpty);
        expect(audio.error, isNull);
      }
      await tester.runAsync(() async {
        final start = audio.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await audio.stop();
        await start;
      });
      expect(audio.running, false);
      await windowManager.setSize(const Size(680, 520));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      debugPrint(
        'LOCAL_STREAMING_RESULT ${jsonEncode({'firstTextMs': firstTextMs, 'textRequests': provider.inputs.length, 'ocr': ocr.text, 'history': window.history!.length})}',
      );
    } finally {
      await tester.runAsync(audio.stop);
      await capture.stop();
      await window.overlay!.close();
      await window.screenOverlay!.close();
      await WindowsCapturePlatform.channel.invokeMethod<void>(
        'debugDestroyFixture',
      );
      final prefix =
          '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}echopane-local-stream-';
      if (folder.absolute.path.startsWith(prefix)) {
        await folder.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
