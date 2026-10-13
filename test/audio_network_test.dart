import 'dart:async';
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

import 'streaming_audio_test.dart';
import 'translation_test.dart'
    show FakeTranslations, MemoryCredentials, MemorySettings;

class _SlowStopPlatform extends StreamPlatform {
  Completer<void>? pendingStop;
  @override
  Future<void> stop() async {
    await pendingStop?.future;
    await super.stop();
  }
}

// Exercise the actual adapter's outgoing queue and timeout without changing
// the machine's network or passing real credentials to a test server.
class _Socket extends Stream<dynamic> implements WebSocket {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  Completer<void>? blocked;
  bool closed = false;
  @override
  Duration? pingInterval;
  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final raw in stream) {
      if (blocked != null) await blocked!.future;
      if (closed) throw const SocketException('Fixture disconnected');
      final event = jsonDecode(raw as String) as Map<String, dynamic>;
      sent.add(event);
      if (event['type'] == 'session.update') {
        incoming.add(
          jsonEncode({
            'type': 'session.updated',
            'session': {
              'modalities': ['text'],
            },
          }),
        );
      }
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    if (blocked != null && !blocked!.isCompleted) blocked!.complete();
    unawaited(incoming.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BailianAudioSession _sessionFor(_Socket socket) => BailianAudioSession(
  const TranslationSettings(
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  ),
  'fixture',
  connect: (_, _) async => socket,
);

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), true);
}

void main() {
  test('restart waits until failed capture cleanup finishes', () async {
    final platform = _SlowStopPlatform();
    final first = StreamSession(), second = StreamSession();
    var starts = 0;
    final audio = AudioController(platform)
      ..openStream = () async => starts++ == 0 ? first : second;
    try {
      await audio.selectBackend(AudioBackend.cloud);
      await audio.start();
      platform.pendingStop = Completer<void>();
      first.controller.addError(const AudioStreamFailure('Fixture dropped'));
      await until(() => audio.error != null);
      expect(audio.stopping, true);
      await audio.start();
      expect(starts, 1);
      expect(audio.running, false);
      platform.pendingStop!.complete();
      await until(() => !audio.stopping);
      await audio.start();
      expect(starts, 2);
      expect(audio.running, true);
      expect(platform.state['running'], true);
      expect(audio.error, isNull);
    } finally {
      if (platform.pendingStop?.isCompleted == false) {
        platform.pendingStop!.complete();
      }
      await until(() => !audio.stopping);
      await audio.stop();
      audio.dispose();
      await first.controller.close();
      await second.controller.close();
    }
  });

  test(
    'real socket disconnect retains no unfinished history and can restart',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        final interrupted = sockets.length == 1;
        socket.listen((raw) async {
          final event = jsonDecode(raw as String) as Map;
          void send(Map<String, dynamic> value) =>
              socket.add(jsonEncode(value));
          if (event['type'] == 'session.update') {
            send({
              'type': 'session.updated',
              'session': {
                'modalities': ['text'],
              },
            });
          } else if (event['type'] == 'input_audio_buffer.append') {
            send(input('s'));
            send(source('s', interrupted ? 'Unfinished' : 'Restarted'));
            if (interrupted) {
              await Future<void>.delayed(const Duration(milliseconds: 120));
              await socket.close(WebSocketStatus.goingAway);
            } else {
              // Late, reordered events on a fresh connection use reused IDs.
              send(responseDone('r'));
              send(translated('t', 'r', '恢复后的完整译文', done: true));
              send(output('t', 's'));
              send(source('s', 'Restarted', done: true));
            }
          } else if (event['type'] == 'session.finish') {
            send({'type': 'session.finished'});
          }
        });
      });
      final platform = StreamPlatform();
      final audio = AudioController(platform)
        ..openStream = () async => BailianAudioSession(
          const TranslationSettings(
            baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
          ),
          'fixture',
          connect: (_, _) => WebSocket.connect('ws://127.0.0.1:${server.port}'),
        );
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
        platform.state['pcm'] = Uint8List(3200);
        await audio.poll();
        await until(
          () => !audio.running && audio.error != null && !audio.stopping,
        );
        expect(history.length, 0);
        expect(audio.captionTurns, isEmpty);
        expect(platform.state['running'], false);
        await audio.start();
        expect(audio.error, isNull);
        platform.state['pcm'] = Uint8List(3200);
        await audio.poll();
        await until(() => history.length == 1);
        expect(audio.running, true);
        expect(history.entries.single.originals, ['Restarted']);
        expect(history.entries.single.translations, ['恢复后的完整译文']);
        await audio.stop();
        expect(history.length, 1);
        expect(audio.error, isNull);
      } finally {
        await audio.stop();
        audio.dispose();
        history.dispose();
        translation.dispose();
        for (final socket in sockets) {
          await socket.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'delayed sends retain order; overflow stops capture and restart is clean',
    () async {
      final first = _Socket(), second = _Socket();
      final platform = StreamPlatform();
      var starts = 0;
      final audio = AudioController(platform)
        ..openStream = () async => _sessionFor(starts++ == 0 ? first : second);
      try {
        await audio.selectBackend(AudioBackend.cloud);
        await audio.start();
        expect(audio.running, true);
        first.blocked = Completer<void>();
        for (var i = 0; i < 45 && audio.error == null; i++) {
          platform.state['pcm'] = Uint8List.fromList([i, 0]);
          await audio.poll();
        }
        await until(
          () =>
              !audio.running &&
              audio.error != null &&
              !audio.stopping &&
              first.closed,
        );
        expect(platform.state['running'], false);
        expect(audio.captionTurns, isEmpty);
        expect(
          first.sent.where((e) => e['type'] == 'input_audio_buffer.append'),
          isEmpty,
        );
        await audio.start();
        expect(audio.running, true);
        expect(audio.error, isNull);
        second.blocked = Completer<void>();
        for (var i = 1; i <= 3; i++) {
          platform.state['pcm'] = Uint8List.fromList([i, 0]);
          await audio.poll();
        }
        second.blocked!.complete();
        await until(() => second.sent.length == 4);
        expect(
          second.sent
              .skip(1)
              .map((e) => base64Decode(e['audio'] as String).first),
          [1, 2, 3],
        );
      } finally {
        // Failure/close is deliberate; do not wait for a clean server EOF.
        await first.close();
        await second.close();
        await settle();
        await audio.stop();
        audio.dispose();
      }
    },
  );

  test(
    'a stalled send fails within its timeout and closes the socket',
    () async {
      final socket = _Socket();
      final session = _sessionFor(socket);
      final errors = <Object>[];
      final subscription = session.updates.listen((_) {}, onError: errors.add);
      try {
        await session.ready;
        socket.blocked = Completer<void>();
        session.addPcm(Uint8List(3200));
        await Future<void>.delayed(const Duration(milliseconds: 3300));
        expect(errors.single, isA<AudioStreamFailure>());
        expect(socket.closed, true);
        await expectLater(session.finish(), throwsA(isA<AudioStreamFailure>()));
      } finally {
        await session.cancel();
        await subscription.cancel();
        await socket.close();
      }
    },
  );
}
