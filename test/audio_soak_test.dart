import 'dart:convert';

import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/bailian_audio.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/history/caption_history.dart';
import 'package:echopane/subtitles/audio_presentation.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'streaming_audio_test.dart';
import 'translation_test.dart'
    show FakeTranslations, MemoryCredentials, MemorySettings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'twenty virtual minutes preserve final pairs and bound retained state',
    () async {
      final decoder = BailianAudioDecoder();
      final platform = StreamPlatform(), session = StreamSession();
      final restarted = StreamSession();
      var starts = 0;
      final audio = AudioController(platform)
        ..openStream = () async => starts++ == 0 ? session : restarted;
      final provider = FakeTranslations();
      final translation = TranslationController(
        audio,
        provider,
        MemorySettings(),
        MemoryCredentials(),
      );
      final history = CaptionHistory(
        audio,
        translation,
        origin: () => RecognitionMode.audio,
      );
      final presentation = AudioSubtitlePresentation();
      const count = 2400;
      try {
        await audio.selectBackend(AudioBackend.cloud);
        await audio.start();
        for (var i = 0; i < count; i++) {
          final now = Duration(milliseconds: i * 500);
          void accept(Map<String, dynamic> event) {
            for (final update in decoder.accept(event, now: now)) {
              session.controller.add(update);
            }
          }

          accept(input('s$i'));
          // Source revisions and duplicated final events must never duplicate history.
          accept(source('s$i', 'Temporary $i'));
          if (i.isEven) {
            accept(responseDone('r$i'));
            accept(translated('t$i', 'r$i', '译文$i', done: true));
            accept(output('t$i', 's$i'));
            accept(source('s$i', 'Sentence $i', done: true));
          } else {
            accept(output('t$i', 's$i'));
            accept(source('s$i', 'Sentence $i', done: true));
            accept(translated('t$i', 'r$i', '译文$i', done: true));
            accept(responseDone('r$i'));
          }
          accept(responseDone('r$i'));
          await settle();
          presentation.update(audio.captionTurns, now);
          final rows = presentation.layout(
            width: i % 3 == 0 ? 300 : 720,
            height: 220,
            settings: const OverlaySettings(),
            locked: false,
            now: now,
          );
          expect(rows.length, lessThanOrEqualTo(4));
          expect(rows.map((r) => r.text).join(), isNot(contains('…')));
          expect(audio.captionTurns.length, lessThanOrEqualTo(8));
          expect(audio.captionConfirmed!.length, lessThanOrEqualTo(64));
          expect(audio.diagnostics.length, lessThanOrEqualTo(128));
          expect(decoder.diagnostics.length, lessThanOrEqualTo(128));
          expect(history.length, lessThanOrEqualTo(1000));
          expect(audio.error, isNull);
        }
        expect(history.length, 1000);
        expect(history.dropped, count - 1000);
        for (var i = 0; i < history.length; i++) {
          final index = count - 1000 + i;
          expect(history.entries[i].originals, ['Sentence $index']);
          expect(history.entries[i].translations, ['译文$index']);
        }
        expect(provider.requests, isEmpty);
        expect(decoder.takeNotices(), isEmpty);
        final diagnostic = jsonEncode(audio.diagnostics);
        expect(diagnostic, isNot(contains('Sentence')));
        expect(diagnostic, isNot(contains('译文')));
        await audio.stop();
        expect(audio.captionTurns, isEmpty);
        expect(history.length, 1000);
        await audio.start();
        restarted.controller.add(
          const SpeechUpdate(
            id: 's0',
            source: 'Restart',
            translation: '重新开始',
            isFinal: true,
          ),
        );
        await settle();
        expect(audio.text, 'Restart');
        expect(history.entries.last.originals, ['Restart']);
        expect(history.dropped, count - 1000 + 1);
      } finally {
        await audio.stop();
        audio.dispose();
        history.dispose();
        translation.dispose();
        await session.controller.close();
        await restarted.controller.close();
      }
    },
  );
}
