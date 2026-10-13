import 'dart:convert';

import 'package:echopane/audio/audio_latency.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'separates receipt, finalization and successful subtitle submission',
    () {
      var now = Duration.zero;
      final timing = AudioLatencyTracker(now: () => now);
      now = const Duration(milliseconds: 100);
      timing.pcm(3200);
      now = const Duration(milliseconds: 150);
      timing.receive(
        const SpeechUpdate(
          id: 'private-id',
          source: 'Private source',
          translation: '',
          sequence: 4,
        ),
      );
      now = const Duration(milliseconds: 170);
      timing.presented('private-id', translated: false);
      now = const Duration(milliseconds: 190);
      timing.receive(
        const SpeechUpdate(
          id: 'private-id',
          source: 'Private source',
          translation: '私密译文',
          sequence: 4,
        ),
      );
      now = const Duration(milliseconds: 320);
      timing.presented('private-id', translated: true);
      now = const Duration(milliseconds: 500);
      timing.receive(
        const SpeechUpdate(
          id: 'private-id',
          source: 'Corrected source',
          translation: '最终译文',
          isFinal: true,
          sequence: 4,
        ),
      );
      timing.presented('private-id', translated: true);
      final row = timing.diagnostics.last;
      expect(row['sourceReceivedMs'], 150);
      expect(row['translationReceivedMs'], 190);
      expect(row['sourceToFrameMs'], 20);
      expect(row['translationToFrameMs'], 130);
      expect(row['finalReceivedMs'], 500);
      expect(row['sourceTurn'], 4);
      expect(timing.diagnostics.first['firstPcmQueuedMs'], 100);
      expect(timing.diagnostics.first['pcmQueuedMs'], 100);
      for (final private in [
        'private-id',
        'Private source',
        '私密译文',
        'Corrected source',
        '最终译文',
      ]) {
        expect(jsonEncode(timing.diagnostics), isNot(contains(private)));
      }
    },
  );

  test('empty updates and absent frames do not invent measured latency', () {
    var now = Duration.zero;
    final timing = AudioLatencyTracker(now: () => now);
    timing.receive(
      const SpeechUpdate(id: 'empty', source: '', translation: ''),
    );
    timing.presented('unknown', translated: true);
    expect(timing.diagnostics, isEmpty);
    now = const Duration(milliseconds: 250);
    timing.receive(
      const SpeechUpdate(id: 'source', source: 'Hello', translation: ''),
    );
    timing.presented('source', translated: true);
    expect(timing.diagnostics.last['translationReceivedMs'], isNull);
    expect(timing.diagnostics.last['translationToFrameMs'], isNull);
    expect(timing.diagnostics.last['sourceFrameMs'], isNull);
  });

  test(
    'identical speech turns remain distinct, bounded and session scoped',
    () {
      var now = Duration.zero;
      final timing = AudioLatencyTracker(now: () => now);
      for (int i = 0; i < 700; i++) {
        now += const Duration(milliseconds: 20);
        timing.receive(
          SpeechUpdate(
            id: 'id-$i',
            source: 'Hello',
            translation: '你好',
            isFinal: true,
          ),
        );
      }
      expect(timing.diagnostics, hasLength(33));
      expect(
        timing.diagnostics.skip(1).map((row) => row['turn']).toSet(),
        hasLength(32),
      );
      timing.reset();
      expect(timing.diagnostics, isEmpty);
      now += const Duration(milliseconds: 50);
      timing.receive(
        const SpeechUpdate(id: 'id-699', source: 'Hello', translation: '你好'),
      );
      expect(timing.diagnostics.last['translationReceivedMs'], 50);
      expect(timing.diagnostics.last['turn'], 1);
      expect(timing.diagnostics.last['translationFrameMs'], isNull);
    },
  );
}
