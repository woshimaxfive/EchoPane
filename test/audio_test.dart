import 'dart:async';

import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

class FakeAudio implements AudioPlatform {
  Completer<void>? pending;
  Completer<Map<Object?, Object?>>? polling;
  int stops = 0;
  final state = <Object?, Object?>{
    'running': true,
    'loading': false,
    'session': 1,
    'lines': ['Hello'],
  };
  @override
  Future<void> refresh() async {}
  @override
  Future<void> start(String directory, String device, String language) async {
    await pending?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<Map<Object?, Object?>> snapshot() async =>
      polling == null ? Map.of(state) : await polling!.future;
}

class _Source extends CaptionSource {
  @override
  bool captionRunning = true;
  @override
  String? captionError;
  @override
  List<String> captionLines = ['Same sentence'];
  @override
  String captionSession = '1';
  @override
  int? get captionDisplayId => null;
  @override
  String get waitingCaption => 'Waiting';
  void update() => notifyListeners();
}

void main() {
  test('stop drains pending audio start and ignores late snapshots', () async {
    final platform = FakeAudio()..pending = Completer<void>();
    final models = OcrModelStore(directory: 'unused')..phase = ModelPhase.ready;
    final audio = AudioController(platform, models: models);
    final start = audio.start();
    final stop = audio.stop();
    platform.pending!.complete();
    await start;
    await stop;
    await audio.poll();
    expect(platform.stops, 1);
    expect(audio.running, false);
    expect(audio.lines, isEmpty);
    platform.pending = null;
    await audio.start();
    expect(audio.lines, ['Hello']);
    platform.polling = Completer<Map<Object?, Object?>>();
    final poll = audio.poll();
    await audio.stop();
    platform.polling!.complete(platform.state);
    await poll;
    expect(audio.lines, isEmpty);
    expect(audio.level, 0);
    audio.dispose();
    models.dispose();
  });
  test(
    'audio failure clears source while preserving an explicit retry',
    () async {
      final platform = FakeAudio();
      final models = OcrModelStore(directory: 'unused')
        ..phase = ModelPhase.ready;
      final audio = AudioController(platform, models: models);
      await audio.start();
      platform.state['error'] = 'device';
      await audio.poll();
      expect(audio.running, false);
      expect(audio.lines, isEmpty);
      expect(audio.error, isNotNull);
      platform.state['error'] = '';
      await audio.start();
      expect(audio.running, true);
      expect(audio.error, isNull);
      audio.dispose();
      models.dispose();
    },
  );
  test('same words on a different source invalidate pending translations and cache', () async {
    final screen = _Source(), audio = _Source();
    final router = CaptionRouter(screen, audio);
    final provider = FakeTranslations();
    final credentials = MemoryCredentials()..key = 'fixture';
    final translation = TranslationController(
      router,
      provider,
      MemorySettings(),
      credentials,
      debounce: Duration.zero,
    );
    await translation.initialize();
    translation.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(provider.requests.length, 1);
    router.select(RecognitionMode.audio);
    await Future<void>.delayed(Duration.zero);
    expect(provider.requests[0].cancelled, true);
    provider.requests[0].completer.complete(['stale']);
    await Future<void>.delayed(Duration.zero);
    expect(translation.translations, isEmpty);
    expect(provider.requests.length, 2);
    provider.requests[1].completer.complete(['audio']);
    await Future<void>.delayed(Duration.zero);
    expect(translation.translations, ['audio']);
    audio.captionSession = '2';
    audio.update();
    await Future<void>.delayed(Duration.zero);
    expect(translation.translations, isEmpty);
    expect(provider.requests.length, 3);
    provider.requests[2].completer.complete(['new session']);
    await Future<void>.delayed(Duration.zero);
    translation.dispose();
    router.dispose();
    audio.dispose();
    screen.dispose();
  });
}
