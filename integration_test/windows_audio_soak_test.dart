import 'dart:convert';
import 'dart:io';

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

// Explicitly opt in with ECHO_SOAK_SECONDS and caller-supplied PCM fixtures.
// Repeated batch inference exercises ASR lifetime; it is not a video/VAD benchmark.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const seconds = int.fromEnvironment('ECHO_SOAK_SECONDS');
  testWidgets(
    'repeated multilingual batch inference remains responsive',
    (tester) async {
      const fixtures = String.fromEnvironment('ECHO_AUDIO_FIXTURES');
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      expect(fixtures, isNotEmpty);
      expect(artifacts, isNotEmpty);
      final temp = await Directory.systemTemp.createTemp('echopane-soak-');
      await app.startApplication(
        settingsStore: MemorySettings(),
        credentials: MemoryCredentials(),
        overlaySettingsStore: FileOverlaySettingsStore(
          path: '${temp.path}/subtitles.json',
        ),
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final audio = window.audio!;
      window.captions!.select(RecognitionMode.audio);
      final pcm = {
        for (final lang in ['en', 'ja'])
          lang: await tester.runAsync(
            () => File('$fixtures/$lang.f32').readAsBytes(),
          ),
      };
      final samples = <Map<String, Object?>>[];
      final resources = <Map<String, Object?>>[];
      final clock = Stopwatch()..start();
      Future<void> tick() async {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await audio.poll();
        });
        expect(audio.error, isNull);
        expect(tester.takeException(), isNull);
      }

      Future<void> resource() async {
        final result = await tester.runAsync(
          () => Process.run('powershell', [
            '-NoProfile',
            '-Command',
            '\$p=Get-Process -Id $pid; @{workingBytes=\$p.WorkingSet64; privateBytes=\$p.PrivateMemorySize64; cpuSeconds=\$p.TotalProcessorTime.TotalSeconds} | ConvertTo-Json -Compress',
          ]),
        );
        expect(result!.exitCode, 0);
        resources.add({
          'elapsedSeconds': clock.elapsedMilliseconds / 1000,
          ...Map<String, Object?>.from(
            jsonDecode(result.stdout as String) as Map,
          ),
        });
        await File('$artifacts/audio-soak-progress.json').writeAsString(
          jsonEncode({
            'elapsedSeconds': clock.elapsed.inSeconds,
            'cycles': samples.length,
            'resources': resources,
          }),
          encoding: utf8,
        );
        // ignore: avoid_print
        print(
          'ASR soak: ${clock.elapsed.inSeconds}s, ${samples.length} batches',
        );
      }

      try {
        await audio.start();
        final loading = Stopwatch()..start();
        while (!audio.running && loading.elapsed.inSeconds < 120) {
          await tick();
        }
        expect(audio.running, true);
        await resource();
        while (clock.elapsed.inSeconds < seconds) {
          final lang = samples.length.isEven ? 'en' : 'ja';
          final previous = audio.captionSession;
          final batch = Stopwatch()..start();
          await WindowsAudioPlatform.channel.invokeMethod<void>(
            'debugFixture',
            {
              'directory': audio.models.directory,
              'language': 'auto',
              'pcm': pcm[lang],
            },
          );
          do {
            await tick();
          } while ((audio.captionSession == previous ||
                  audio.starting ||
                  audio.recognizing ||
                  audio.lines.isEmpty) &&
              batch.elapsed.inSeconds < 90);
          expect(audio.lines, isNotEmpty);
          expect(audio.detectedLanguage, lang);
          expect(audio.text, contains(lang == 'en' ? 'gold' : '中学'));
          samples.add({
            'language': lang,
            'inferenceMs': audio.durationMs,
            'observedMs': batch.elapsedMilliseconds,
            'session': audio.captionSession,
          });
          if (clock.elapsed.inSeconds >= resources.length * 60) {
            await resource();
          }
          while (batch.elapsed.inSeconds < 10 &&
              clock.elapsed.inSeconds < seconds) {
            await tick();
          }
        }
        await resource();
        await audio.stop();
        await tick();
        expect(audio.running, false);
        expect(audio.lines, isEmpty);
        await File('$artifacts/audio-soak-results.json').writeAsString(
          jsonEncode({
            'kind': 'repeated offline batch inference',
            'elapsedSeconds': clock.elapsedMilliseconds / 1000,
            'logicalProcessors': Platform.numberOfProcessors,
            'samples': samples,
            'resources': resources,
            'passed': true,
            'cloudTranslation': false,
            'continuousVideo': false,
          }),
          encoding: utf8,
        );
      } finally {
        await audio.stop();
        await window.overlay!.close();
        audio.dispose();
        await tester.runAsync(() => temp.delete(recursive: true));
      }
    },
    skip: seconds <= 0,
    timeout: Timeout(Duration(seconds: seconds + 300)),
  );
}
