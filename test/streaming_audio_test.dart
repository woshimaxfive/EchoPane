import 'dart:async';
import 'dart:typed_data';

import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/bailian_audio.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/history/caption_history.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

Map<String, dynamic> input(String id) => {
  'type': 'conversation.item.created',
  'item': {
    'id': id,
    'content': [
      {'type': 'input_audio'},
    ],
  },
};
Map<String, dynamic> output(String id, String parent) => {
  'type': 'conversation.item.created',
  'previous_item_id': parent,
  'item': {'id': id, 'content': []},
};
Map<String, dynamic> source(String id, String value, {bool done = false}) => {
  'type':
      'conversation.item.input_audio_transcription.${done ? 'completed' : 'text'}',
  'item_id': id,
  'language': 'en',
  if (done) 'transcript': value else 'stash': value,
};
Map<String, dynamic> translated(
  String id,
  String response,
  String value, {
  bool done = false,
}) => {
  'type': 'response.text.${done ? 'done' : 'text'}',
  'item_id': id,
  'response_id': response,
  if (done) 'text': value else 'stash': value,
};
Map<String, dynamic> responseDone(String id, [String status = 'completed']) => {
  'type': 'response.done',
  'response': {'id': id, 'status': status},
};

class StreamPlatform implements AudioPlatform, StreamingAudioPlatform {
  int starts = 0, stops = 0;
  final state = <Object?, Object?>{
    'session': 1,
    'running': false,
    'loading': false,
    'dropped': 0,
    'lines': <String>[],
  };
  @override
  Future<void> startStream(String device) async {
    starts++;
    state['running'] = true;
  }

  @override
  Future<void> start(String directory, String device, String language) async =>
      startStream(device);
  @override
  Future<void> stop() async {
    stops++;
    state['running'] = false;
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<Map<Object?, Object?>> snapshot() async {
    final next = Map<Object?, Object?>.of(state);
    state.remove('pcm');
    return next;
  }
}

class StreamSession implements AudioStreamSession {
  final controller = StreamController<SpeechUpdate>();
  Completer<void>? connecting;
  SpeechUpdate? last;
  int bytes = 0, finishes = 0, cancels = 0;
  @override
  Stream<SpeechUpdate> get updates => controller.stream;
  @override
  Future<void> get ready => connecting?.future ?? Future.value();
  @override
  void addPcm(Uint8List pcm) {
    bytes += pcm.length;
  }

  @override
  Future<void> finish() async {
    finishes++;
    if (last != null) controller.add(last!);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (connecting?.isCompleted == false) connecting!.complete();
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'vendor snapshots revise text and only paired completed responses finalize',
    () {
      final decoder = BailianAudioDecoder();
      decoder.accept(input('s1'));
      decoder.accept(output('t1', 's1'));
      expect(
        decoder.accept(source('s1', 'The trial')).single.source,
        'The trial',
      );
      expect(
        decoder.accept(source('s1', 'The tribal chief')).single.source,
        'The tribal chief',
      );
      expect(
        decoder.accept(translated('t1', 'r1', '部落')).single.translation,
        '部落',
      );
      expect(
        decoder.accept(translated('t1', 'r1', '部落首领')).single.translation,
        '部落首领',
      );
      expect(
        decoder
            .accept(translated('t1', 'r1', '部落首领。', done: true))
            .single
            .isFinal,
        false,
      );
      expect(decoder.accept(responseDone('r1')).single.isFinal, false);
      final done = decoder
          .accept(source('s1', 'The tribal chief.', done: true))
          .single;
      expect(done.isFinal, true);
      expect(done.translation, '部落首领。');
      expect(
        decoder.accept(source('s1', 'wrong late partial')).single.source,
        done.source,
      );
    },
  );

  test('overlapping and identical turns use message links instead of arrival order', () {
    final decoder = BailianAudioDecoder();
    for (final id in ['1', '2']) {
      decoder.accept(input('s$id'));
      decoder.accept(output('t$id', 's$id'));
      decoder.accept(source('s$id', 'Hello', done: true));
      decoder.accept(translated('t$id', 'r$id', '你好$id', done: true));
    }
    expect(decoder.accept(responseDone('r1')).single.id, 's1');
    expect(decoder.accept(responseDone('r2')).single.translation, '你好2');
    expect(
      () => decoder.accept(translated('unlinked', 'r3', 'must not be paired')),
      throwsA(isA<AudioStreamFailure>()),
    );
  });

  test('interrupted text.done never becomes a complete history entry', () {
    final decoder = BailianAudioDecoder()
      ..accept(input('s'))
      ..accept(output('t', 's'));
    decoder.accept(source('s', 'Hello', done: true));
    expect(
      decoder.accept(translated('t', 'r', '你好', done: true)).single.isFinal,
      false,
    );
    expect(
      () => decoder.accept(responseDone('r', 'incomplete')),
      throwsA(isA<AudioStreamFailure>()),
    );
  });

  test('credential destinations are restricted to verified Beijing realtime endpoints', () {
    expect(
      bailianAudioEndpoint(
        const TranslationSettings(
          baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        ),
      ).host,
      'dashscope.aliyuncs.com',
    );
    expect(
      bailianAudioEndpoint(
        const TranslationSettings(
          baseUrl: 'https://workspace-id.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
        ),
      ).scheme,
      'wss',
    );
    for (final host in [
      'https://evil.example',
      'https://dashscope.aliyuncs.com.evil.example',
      'https://dashscope-intl.aliyuncs.com',
    ]) {
      expect(
        () => bailianAudioEndpoint(TranslationSettings(baseUrl: host)),
        throwsA(isA<AudioStreamFailure>()),
      );
    }
    expect(
      () => bailianAudioTarget('zh-Hant'),
      throwsA(isA<AudioStreamFailure>()),
    );
  });

  test('cloud revisions reuse captions without text requests; history records final pairs once', () async {
    final platform = StreamPlatform(), stream = StreamSession();
    final models = OcrModelStore(directory: 'unused')
      ..phase = ModelPhase.missing;
    final audio = AudioController(platform, models: models);
    audio.openStream = () async => stream;
    audio.streamTarget = () => 'zh-Hans';
    await audio.selectBackend(AudioBackend.cloud);
    final provider = FakeTranslations();
    final translation = TranslationController(
      audio,
      provider,
      MemorySettings(),
      MemoryCredentials()..key = 'fixture',
    );
    final history = CaptionHistory(
      audio,
      translation,
      origin: () => RecognitionMode.audio,
    );
    await translation.initialize();
    translation.setEnabled(true);
    await audio.start();
    expect(platform.starts, 1);
    platform.state['pcm'] = Uint8List(3200);
    await audio.poll();
    expect(stream.bytes, 3200);
    stream.controller.add(
      const SpeechUpdate(id: '1', source: 'The trial', translation: '部落'),
    );
    await settle();
    expect(history.length, 0);
    expect(audio.provisional, true);
    stream.controller.add(
      const SpeechUpdate(
        id: '1',
        source: 'The tribal chief',
        translation: '部落首领',
        isFinal: true,
      ),
    );
    await settle();
    expect(history.length, 1);
    expect(translation.translations, ['部落首领']);
    stream.controller.add(
      const SpeechUpdate(id: '2', source: 'Hello', translation: '你好'),
    );
    await settle();
    stream.controller.add(
      const SpeechUpdate(
        id: '1',
        source: 'The tribal chief',
        translation: '部落首领',
        isFinal: true,
      ),
    );
    await settle();
    expect(audio.text, 'Hello');
    expect(history.length, 1);
    stream.last = const SpeechUpdate(
      id: '2',
      source: 'Hello',
      translation: '你好',
      isFinal: true,
    );
    await audio.stop();
    expect(stream.finishes, 1);
    expect(history.length, 2);
    expect(audio.lines, isEmpty);
    expect(provider.requests, isEmpty);
    history.dispose();
    translation.dispose();
    audio.dispose();
    models.dispose();
    await stream.controller.close();
  });

  test('cancel during cloud handshake cannot start capture later', () async {
    final platform = StreamPlatform(),
        stream = StreamSession()..connecting = Completer<void>();
    final audio = AudioController(platform)..openStream = () async => stream;
    await audio.selectBackend(AudioBackend.cloud);
    final starting = audio.start();
    await settle();
    await audio.poll();
    expect(audio.starting, true);
    await audio.stop();
    await starting;
    expect(platform.starts, 0);
    expect(audio.running, false);
    expect(audio.starting, false);
    audio.dispose();
    audio.models.dispose();
    await stream.controller.close();
  });

  test('device reroute terminates cloud session instead of mixing new audio with old text', () async {
    final platform = StreamPlatform(), stream = StreamSession();
    final audio = AudioController(platform)..openStream = () async => stream;
    await audio.selectBackend(AudioBackend.cloud);
    await audio.start();
    stream.controller.add(
      const SpeechUpdate(id: '1', source: 'old', translation: '旧'),
    );
    await settle();
    platform.state['session'] = 2;
    await audio.poll();
    await settle();
    expect(audio.running, false);
    expect(audio.error, isNotNull);
    expect(audio.lines, isEmpty);
    expect(stream.cancels, greaterThan(0));
    stream.controller.add(
      const SpeechUpdate(
        id: '1',
        source: 'late',
        translation: '迟到',
        isFinal: true,
      ),
    );
    await settle();
    expect(audio.lines, isEmpty);
    audio.dispose();
    audio.models.dispose();
    await stream.controller.close();
  });
}
