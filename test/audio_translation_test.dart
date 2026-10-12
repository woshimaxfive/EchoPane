import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/translation/audio_translation.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/history/caption_history.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeTranslations, MemoryCredentials, MemorySettings;
import 'streaming_audio_test.dart' show StreamPlatform, StreamSession;

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('local partials stay out of history and late final translation updates the right entry', () async {
    final platform = StreamPlatform();
    final session = StreamSession();
    final audio = AudioController(platform);
    await audio.selectBackend(AudioBackend.localStreaming);
    audio.streamingModels.phase = ModelPhase.ready;
    audio.openLocalStream = () async => session;
    final provider = FakeTranslations();
    final translation = TranslationController(
      audio,
      provider,
      MemorySettings(),
      MemoryCredentials()..key = 'fixture',
    );
    await translation.initialize();
    final history = CaptionHistory(audio, translation);
    await audio.start();
    translation.setEnabled(true);
    session.controller.add(
      const SpeechUpdate(id: 'one', source: 'Hello', translation: ''),
    );
    await settle();
    expect(history.length, 0);
    session.controller.add(
      const SpeechUpdate(
        id: 'one',
        source: 'Hello world.',
        translation: '',
        isFinal: true,
      ),
    );
    await settle();
    expect(history.length, 1);
    expect(history.entries.single.translations, isEmpty);
    session.controller.add(
      const SpeechUpdate(id: 'two', source: 'Next', translation: ''),
    );
    await settle();
    provider.requests.single.completer.complete(['你好，世界。']);
    await settle();
    expect(history.length, 1);
    expect(history.entries.single.originals, ['Hello world.']);
    expect(history.entries.single.translations, ['你好，世界。']);
    expect(audio.lines, ['Next']);
    translation.setEnabled(false);
    expect(audio.running, true);
    session.controller.add(
      const SpeechUpdate(
        id: 'two',
        source: 'Next sentence.',
        translation: '',
        isFinal: true,
      ),
    );
    await settle();
    expect(history.length, 2);
    expect(history.entries.last.translations, isEmpty);
    await audio.stop();
    history.dispose();
    translation.dispose();
    audio.dispose();
    await session.controller.close();
  });

  test('continuing speech does not cancel translation; final revision replaces partial by ID', () async {
    final provider = FakeTranslations();
    final queue = AudioTranslationQueue(provider);
    const settings = TranslationSettings();
    queue.update(
      [const CaptionTurn('one', 'The tribal chieftain called for', '', false)],
      settings,
      '',
    );
    queue.update(
      [
        const CaptionTurn(
          'one',
          'The tribal chieftain called for the boy',
          '',
          false,
        ),
      ],
      settings,
      '',
    );
    expect(provider.requests, hasLength(1));
    queue.update(
      [
        const CaptionTurn(
          'one',
          'The tribal chieftain called for the boy.',
          '',
          true,
        ),
      ],
      settings,
      '',
    );
    queue.update(
      [const CaptionTurn('two', 'Another sentence.', '', true)],
      settings,
      '',
    );
    expect(provider.requests, hasLength(1));
    expect(provider.requests.first.cancelled, false);
    provider.requests.first.completer.complete(['首领召唤']);
    await settle();
    expect(queue.result('one')!.isFinal, false);
    expect(provider.requests, hasLength(2));
    provider.requests[1].completer.complete(['首领召唤男孩。']);
    await settle();
    expect(queue.result('one')!.isFinal, true);
    expect(queue.result('one')!.text, '首领召唤男孩。');
    expect(provider.requests, hasLength(3));
    provider.requests[2].completer.complete(['另一句。']);
    await settle();
    expect(queue.result('two')!.text, '另一句。');
    expect(queue.result('one')!.text, '首领召唤男孩。');
    queue.dispose();
  });

  test(
    'short unstable tokens do not cause requests; quiet complete words do',
    () async {
      final provider = FakeTranslations();
      final queue = AudioTranslationQueue(
        provider,
        quiet: const Duration(milliseconds: 5),
      );
      queue.update(
        [const CaptionTurn('one', 'THE CHI', '', false)],
        const TranslationSettings(),
        '',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(provider.requests, isEmpty);
      queue.update(
        [
          const CaptionTurn(
            'one',
            'The tribal chieftain called for',
            '',
            false,
          ),
        ],
        const TranslationSettings(),
        '',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(provider.requests, hasLength(1));
      expect(provider.inputs.single, ['The tribal chieftain called']);
      queue.dispose();
      provider.requests.single.completer.complete(['首领召唤']);
      await settle();
    },
  );

  test(
    'old response after reset cannot enter the next recognition session',
    () async {
      final provider = FakeTranslations();
      final queue = AudioTranslationQueue(provider);
      queue.update(
        [const CaptionTurn('local:0', 'Old sentence.', '', true)],
        const TranslationSettings(),
        '',
      );
      queue.reset();
      queue.update(
        [const CaptionTurn('local:0', 'New sentence.', '', true)],
        const TranslationSettings(),
        '',
      );
      expect(provider.requests, hasLength(2));
      provider.requests.first.completer.complete(['旧句。']);
      await settle();
      expect(queue.result('local:0'), isNull);
      provider.requests.last.completer.complete(['新句。']);
      await settle();
      expect(queue.result('local:0')!.text, '新句。');
      queue.dispose();
    },
  );

  test(
    'translation failure keeps recognition turns and allows manual retry',
    () async {
      final provider = FakeTranslations();
      final queue = AudioTranslationQueue(provider);
      queue.update(
        [const CaptionTurn('one', 'Hello.', '', true)],
        const TranslationSettings(),
        '',
      );
      provider.requests.single.completer.completeError(StateError('offline'));
      await settle();
      expect(queue.error, isNotNull);
      expect(queue.result('one'), isNull);
      queue.retry();
      provider.requests.last.completer.complete(['你好。']);
      await settle();
      expect(queue.result('one')!.isFinal, true);
      queue.dispose();
    },
  );
}
