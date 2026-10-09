import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

class _Session implements AudioStreamSession {
  final events = StreamController<SpeechUpdate>();
  int bytes = 0;
  bool sound = false;
  @override
  Stream<SpeechUpdate> get updates => events.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  void addPcm(Uint8List pcm) {
    bytes += pcm.length;
    sound |= pcm.any((value) => value != 0);
    if (sound) {
      events.add(
        const SpeechUpdate(
          id: 'fixture',
          source: 'Native audio',
          translation: '原生音频',
        ),
      );
    }
  }

  @override
  Future<void> finish() async {
    if (sound) {
      events.add(
        const SpeechUpdate(
          id: 'fixture',
          source: 'Native audio',
          translation: '原生音频',
          isFinal: true,
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'WASAPI PCM capture streams without local weights and keeps finalized captions',
    (tester) async {
      const fixtures = String.fromEnvironment('ECHO_AUDIO_FIXTURES');
      expect(fixtures, isNotEmpty);
      final folder = await Directory.systemTemp.createTemp(
        'echopane-stream-test-',
      );
      final sessions = <_Session>[];
      await app.startApplication(
        settingsStore: MemorySettings(),
        credentials: MemoryCredentials()..key = 'fixture',
        audioStreamFactory: () async {
          final session = _Session();
          sessions.add(session);
          return session;
        },
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
      window.captions!.select(RecognitionMode.audio);
      window.translation!.setEnabled(true);
      await audio.selectBackend(AudioBackend.cloud);
      Future<void> until(bool Function() done) async {
        final clock = Stopwatch()..start();
        while (!done() && clock.elapsed.inSeconds < 12) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await audio.poll();
          });
        }
        expect(done(), true, reason: audio.error);
      }

      try {
        await audio.start();
        await until(() => audio.running);
        final pcm = await File('$fixtures/en.f32').readAsBytes();
        await WindowsAudioPlatform.channel.invokeMethod<void>('debugPlay', {
          'pcm': pcm,
        });
        await until(
          () => sessions.single.sound && sessions.single.bytes > 16000,
        );
        await until(() => window.translation!.translations.isNotEmpty);
        expect(audio.dropped, 0);
        expect(window.history!.length, 0);
        await window.overlay!.show(true);
        await tester.pump(const Duration(milliseconds: 300));
        expect(window.overlay!.translations, ['原生音频']);
        await audio.stop();
        expect(window.history!.length, 1);
        expect(audio.lines, isEmpty);
        await audio.start();
        await until(() => audio.running);
        window.translation!.setEnabled(false);
        await until(() => !audio.running && !audio.stopping);
        expect(audio.lines, isEmpty);
        window.translation!.setEnabled(true);
        await audio.start();
        await until(() => audio.running);
        await WindowsAudioPlatform.channel.invokeMethod<void>('debugReroute');
        await until(() => audio.error != null);
        expect(audio.running, false);
        expect(audio.lines, isEmpty);
        await audio.start();
        await until(() => audio.running);
        await audio.stop();
        await windowManager.setSize(const Size(680, 520));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
      } finally {
        await audio.stop();
        await window.overlay!.close();
        await window.screenOverlay!.close();
        for (final session in sessions) {
          await session.events.close();
        }
        final prefix =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}echopane-stream-test-';
        if (folder.absolute.path.startsWith(prefix)) {
          await tester.runAsync(() => folder.delete(recursive: true));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
