import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/bailian_audio.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/history/caption_history.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'streaming_audio_test.dart'
    show
        input,
        output,
        source,
        translated,
        responseDone,
        StreamPlatform,
        StreamSession,
        settle;
import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

Iterable<List<T>> permutations<T>(List<T> items) sync* {
  if (items.isEmpty) {
    yield [];
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final rest = [...items]..removeAt(i);
    for (final tail in permutations(rest)) {
      yield [items[i], ...tail];
    }
  }
}

void main() {
  test(
    'all 120 arrival orders retain the source, translation and final status',
    () {
      final events = [
        input('s'),
        output('t', 's'),
        source('s', 'Hello', done: true),
        translated('t', 'r', '你好', done: true),
        responseDone('r'),
      ];
      for (final order in permutations(events)) {
        final decoder = BailianAudioDecoder();
        final updates = [for (final event in order) ...decoder.accept(event)];
        expect(updates.last.source, 'Hello');
        expect(updates.last.translation, '你好');
        expect(updates.last.isFinal, true);
        expect(decoder.takeNotices(), isEmpty);
      }
    },
  );

  test(
    'VAD registers order before text; late originals retain the correct turn',
    () {
      final decoder = BailianAudioDecoder();
      for (final id in ['old', 'new']) {
        decoder.accept({
          'type': 'input_audio_buffer.speech_started',
          'item_id': id,
        });
        decoder.accept(output('t$id', id));
      }
      final newer = decoder.accept(translated('tnew', 'rnew', '新句')).single;
      final older = decoder.accept(translated('told', 'rold', '旧句')).single;
      expect(older.sequence!, lessThan(newer.sequence!));
      expect(decoder.accept(source('old', 'Old')).single.translation, '旧句');
      expect(decoder.accept(source('new', 'New')).single.translation, '新句');
    },
  );

  test('duplicate completion and late partials do not corrupt final text', () {
    final decoder = BailianAudioDecoder()
      ..accept(input('s'))
      ..accept(output('t', 's'));
    decoder.accept(source('s', 'Hello', done: true));
    decoder.accept(translated('t', 'r', '你好', done: true));
    decoder.accept(responseDone('r'));
    expect(
      decoder.accept(translated('t', 'r', 'wrong')).single.translation,
      '你好',
    );
    expect(decoder.accept(responseDone('r')).single.isFinal, true);
    expect(decoder.accept(source('s', 'wrong')).single.source, 'Hello');
  });

  test(
    'unlinked items wait, expire once, and three consecutive failures stop',
    () {
      final decoder = BailianAudioDecoder();
      for (var i = 0; i < 3; i++) {
        final now = Duration(seconds: i * 10);
        decoder.accept(translated('t$i', 'r$i', 'private'), now: now);
        expect(decoder.expire(now + const Duration(seconds: 4)), isEmpty);
        if (i == 2) {
          expect(
            () => decoder.expire(now + const Duration(seconds: 5)),
            throwsA(isA<AudioStreamFailure>()),
          );
        } else {
          decoder.expire(now + const Duration(seconds: 5));
          expect(decoder.takeNotices(), hasLength(1));
          decoder.expire(now + const Duration(seconds: 6));
          expect(decoder.takeNotices(), isEmpty);
        }
      }
    },
  );

  test(
    'a completed original without a translation is skipped once after grace',
    () {
      final decoder = BailianAudioDecoder();
      decoder.accept(source('s', 'Original', done: true));
      expect(decoder.expire(const Duration(seconds: 4)), isEmpty);
      final skipped = decoder.expire(const Duration(seconds: 5)).single;
      expect(skipped.source, 'Original');
      expect(skipped.isFinal, false);
      expect(decoder.takeNotices(), hasLength(1));
      decoder.expire(const Duration(seconds: 6));
      expect(decoder.takeNotices(), isEmpty);
    },
  );

  test('response trimming retains a linked pending response', () {
    final decoder = BailianAudioDecoder()..accept(output('t', 's'));
    decoder.accept(translated('t', 'pending', '译文', done: true));
    decoder.accept(responseDone('pending'));
    for (var i = 0; i < 300; i++) {
      decoder.accept(responseDone('unused$i'));
    }
    expect(
      decoder.accept(source('s', 'Original', done: true)).single.isFinal,
      true,
    );
  });

  test('a long active sentence is not timed out while ASR is progressing', () {
    final decoder = BailianAudioDecoder()..accept(output('t', 's'));
    decoder.accept(translated('t', 'r', '译文', done: true));
    decoder.expire(const Duration(minutes: 1));
    expect(decoder.takeNotices(), isEmpty);
    decoder.accept(responseDone('r'), now: const Duration(minutes: 1));
    decoder.accept(
      source('s', 'Still speaking'),
      now: const Duration(seconds: 64),
    );
    decoder.expire(const Duration(seconds: 68));
    expect(decoder.takeNotices(), isEmpty);
    expect(
      decoder
          .accept(
            source('s', 'Done', done: true),
            now: const Duration(seconds: 68),
          )
          .single
          .isFinal,
      true,
    );
  });

  test(
    'unfinished drain produces a notice and cannot finalize an incomplete pair',
    () {
      final decoder = BailianAudioDecoder()..accept(output('t', 's'));
      decoder.accept(translated('t', 'r', '译文', done: true));
      decoder.accept(responseDone('r'));
      expect(
        decoder.expire(Duration.zero, finished: true).single.isFinal,
        false,
      );
      expect(decoder.takeNotices(), hasLength(1));
      final late = decoder.accept(source('s', 'late', done: true)).single;
      expect(late.isFinal, false);
      expect(late.translation, isEmpty);
    },
  );

  test(
    'completed old turns are trimmed; pending turns survive long sessions',
    () {
      final decoder = BailianAudioDecoder()
        ..accept(input('pending'))
        ..accept(output('tp', 'pending'));
      decoder.accept(source('pending', 'Pending'));
      for (var i = 0; i < 700; i++) {
        decoder.accept(input('s$i'));
        decoder.accept(output('t$i', 's$i'));
        decoder.accept(source('s$i', 'Hello', done: true));
        decoder.accept(translated('t$i', 'r$i', '你好', done: true));
        decoder.accept(responseDone('r$i'));
      }
      decoder.accept(translated('tp', 'rp', '等待句', done: true));
      decoder.accept(responseDone('rp'));
      expect(
        decoder.accept(source('pending', 'Pending', done: true)).single.isFinal,
        true,
      );
      final trace = jsonEncode(decoder.diagnostics);
      expect(decoder.diagnostics.length, lessThanOrEqualTo(128));
      for (final private in ['Hello', '你好', 'Pending', 'pending', '等待句']) {
        expect(trace, isNot(contains(private)));
      }
      decoder.clear();
      expect(
        decoder.accept(source('fresh', 'Fresh')).single.translation,
        isEmpty,
      );
    },
  );

  test('conflicting explicit links fail rather than guess a sentence', () {
    final decoder = BailianAudioDecoder()..accept(output('t', 'a'));
    expect(
      () => decoder.accept(output('t', 'b')),
      throwsA(isA<AudioStreamFailure>()),
    );
  });

  test('cancelled response preceding the link preserves late original without a second failure', () {
    final decoder = BailianAudioDecoder();
    decoder.accept(responseDone('r', 'cancelled'));
    decoder.accept(translated('t', 'r', 'unfinished', done: true));
    expect(decoder.takeNotices(), hasLength(1));
    decoder.accept(output('t', 's'));
    final original = decoder.accept(source('s', 'Original', done: true)).single;
    expect(original.source, 'Original');
    expect(original.translation, isEmpty);
    expect(original.isFinal, false);
    decoder.expire(const Duration(seconds: 20));
    expect(decoder.takeNotices(), isEmpty);
  });

  test(
    'late older turns and nonfatal notices preserve current audio and history',
    () async {
      final platform = StreamPlatform(), session = StreamSession();
      final audio = AudioController(platform)..openStream = () async => session;
      final translation = TranslationController(
        audio,
        FakeTranslations(),
        MemorySettings(),
        MemoryCredentials(),
      );
      final history = CaptionHistory(
        audio,
        translation,
        origin: () => RecognitionMode.audio,
      );
      try {
        await audio.selectBackend(AudioBackend.cloud);
        await audio.start();
        session.controller.add(
          const SpeechUpdate(
            id: 'new',
            source: 'New',
            translation: '新',
            sequence: 2,
          ),
        );
        await settle();
        session.controller.add(
          const SpeechUpdate(
            id: 'old',
            source: 'Old',
            translation: '旧',
            sequence: 1,
          ),
        );
        session.controller.addError(
          const AudioStreamNotice('Skipped one turn'),
        );
        await settle();
        expect(audio.text, 'New');
        expect(audio.captionTurns.map((t) => t.id), ['old', 'new']);
        expect(audio.running, true);
        expect(audio.error, isNull);
        expect(audio.notice, isNotNull);
        expect(history.length, 0);
        for (var i = 0; i < 2; i++) {
          session.controller.add(
            const SpeechUpdate(
              id: 'old',
              source: 'Old',
              translation: '旧',
              sequence: 1,
              isFinal: true,
            ),
          );
        }
        await settle();
        expect(history.length, 1);
        expect(audio.text, 'New');
        expect(audio.notice, isNull);
      } finally {
        await audio.stop();
        audio.dispose();
        history.dispose();
        translation.dispose();
        await session.controller.close();
      }
    },
  );

  test(
    'real WebSocket session handles reordered frames, notices and clean drain',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      final peers = server.listen((request) async {
        peer = await WebSocketTransformer.upgrade(request);
        peer!.listen((raw) {
          final request = jsonDecode(raw as String) as Map;
          void send(Map<String, dynamic> event) => peer!.add(jsonEncode(event));
          if (request['type'] == 'session.update') {
            send({
              'type': 'session.updated',
              'session': {
                'modalities': ['text'],
              },
            });
          } else if (request['type'] == 'input_audio_buffer.append') {
            send(responseDone('r'));
            send(translated('t', 'r', '你好', done: true));
            send(output('t', 's'));
            send(source('s', 'Hello', done: true));
            send(output('broken', 'no-asr'));
            send(translated('broken', 'broken-r', 'orphan', done: true));
          } else if (request['type'] == 'session.finish') {
            send({'type': 'session.finished'});
          }
        });
      });
      final session = BailianAudioSession(
        const TranslationSettings(
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        ),
        'fixture',
        connect: (endpoint, headers) {
          expect(endpoint.host, 'dashscope.aliyuncs.com');
          expect(headers['Authorization'], 'Bearer fixture');
          return WebSocket.connect('ws://127.0.0.1:${server.port}');
        },
      );
      final updates = <SpeechUpdate>[], failures = <Object>[];
      final subscription = session.updates.listen(
        updates.add,
        onError: failures.add,
      );
      try {
        await session.ready;
        session.addPcm(Uint8List(320));
        for (var i = 0; i < 100 && !updates.any((u) => u.isFinal); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(updates.where((u) => u.isFinal).single.translation, '你好');
        await session.finish();
        await settle();
        expect(failures.single, isA<AudioStreamNotice>());
        expect(jsonEncode(session.diagnostics), isNot(contains('Hello')));
      } finally {
        await session.cancel();
        await subscription.cancel();
        await peer?.close();
        await peers.cancel();
        await server.close(force: true);
      }
    },
  );
}
