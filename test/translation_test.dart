import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:echopane/capture/capture_controller.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/ocr/ocr_controller.dart';
import 'package:echopane/translation/provider.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'capture_controller_test.dart' show FakePlatform;
import 'ocr_test.dart' show FakeOcr;

class MemoryCredentials implements CredentialStore {
  String? key;
  bool fail = false;
  @override
  Future<String?> read() async => key;
  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('Store unavailable');
    key = value;
  }

  @override
  Future<void> delete() async {
    key = null;
  }
}

class MemorySettings implements SettingsStore {
  TranslationSettings value = const TranslationSettings();
  @override
  Future<TranslationSettings> read() async => value;
  @override
  Future<void> write(TranslationSettings settings) async => value = settings;
}

class PendingTranslation implements TranslationRequest {
  final completer = Completer<List<String>>();
  bool cancelled = false;
  @override
  Future<List<String>> get result => completer.future;
  @override
  void cancel() => cancelled = true;
}

class FakeTranslations implements TranslationProvider {
  final requests = <PendingTranslation>[];
  final inputs = <List<String>>[];
  @override
  TranslationRequest translate(
    TranslationSettings settings,
    String key,
    List<String> lines,
  ) {
    inputs.add(List.of(lines));
    final request = PendingTranslation();
    requests.add(request);
    return request;
  }
}

Map<String, Object> completion(Object content, {String finish = 'stop'}) => {
  'choices': [
    {
      'finish_reason': finish,
      'message': {'content': content},
    },
  ],
};

void main() {
  test('real HTTP request preserves Unicode and maps output ids', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = Completer<Map<String, dynamic>>();
    final subscription = server.listen((request) async {
      expect(request.uri.path, '/v1/chat/completions');
      expect(request.headers.value('authorization'), 'Bearer test-key');
      final payload =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      seen.complete(payload);
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(
          completion(
            jsonEncode({
              'translations': [
                {'id': 1, 'text': '我们在这里见面。'},
                {'id': 0, 'text': '天亮前出发。'},
              ],
            }),
          ),
        ),
      );
      await request.response.close();
    });
    try {
      final settings = TranslationSettings(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
      );
      final result = await const ChatTranslationProvider().translate(
        settings,
        'test-key',
        ['Leave before sunrise.', '明日の朝、ここで会いましょう。'],
      ).result;
      expect(result, ['天亮前出发。', '我们在这里见面。']);
      final payload = await seen.future;
      expect(payload['stream'], isFalse);
      expect(payload['thinking'], {'type': 'disabled'});
      expect(payload['response_format'], {'type': 'json_object'});
      expect(payload.containsKey('tools'), isFalse);
      final input = jsonDecode(
        (payload['messages'] as List)[1]['content'] as String,
      ) as Map;
      expect(input['segments'][1]['text'], '明日の朝、ここで会いましょう。');
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  for (final status in [401, 402, 429, 500, 307]) {
    test('HTTP $status is sanitized and never retried or redirected', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      int calls = 0;
      final subscription = server.listen((request) async {
        calls++;
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/stolen',
        );
        request.response.write('private-test-key and screen content');
        await request.response.close();
      });
      try {
        await expectLater(
          const ChatTranslationProvider().translate(
            TranslationSettings(baseUrl: 'http://127.0.0.1:${server.port}'),
            'private-test-key',
            ['Test.'],
          ).result,
          throwsA(
            isA<TranslationFailure>().having(
              (error) => error.message,
              'no raw server body',
              isNot(contains('private-test-key')),
            ),
          ),
        );
        expect(calls, 1);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    });
  }

  final invalid = <String, Object>{
    'plain text': completion('This is not JSON'),
    'missing segment': completion(
      jsonEncode({
        'translations': [
          {'id': 0, 'text': '你好'},
        ],
      }),
    ),
    'duplicate id': completion(
      jsonEncode({
        'translations': [
          {'id': 0, 'text': '一'},
          {'id': 0, 'text': '二'},
        ],
      }),
    ),
    'truncated content': completion('{}', finish: 'length'),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} without misaligned captions', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.write(jsonEncode(entry.value));
        await request.response.close();
      });
      try {
        await expectLater(
          const ChatTranslationProvider().translate(
            TranslationSettings(baseUrl: 'http://127.0.0.1:${server.port}'),
            '',
            ['One', 'Two'],
          ).result,
          throwsA(isA<TranslationFailure>()),
        );
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    });
  }

  test(
    'total timeout works even when service keeps the connection open',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final release = Completer<void>();
      final subscription = server.listen((request) async {
        await request.drain<void>();
        await release.future;
        try {
          await request.response.close();
        } catch (_) {}
      });
      try {
        await expectLater(
          const ChatTranslationProvider(timeout: Duration(milliseconds: 100))
              .translate(
                TranslationSettings(baseUrl: 'http://127.0.0.1:${server.port}'),
                '',
                ['Test'],
              )
              .result,
          throwsA(
            isA<TranslationFailure>().having(
              (error) => error.message,
              'timeout',
              contains('超时'),
            ),
          ),
        );
      } finally {
        release.complete();
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('settings reject insecure remote and credential-bearing URLs', () {
    for (final url in [
      'http://example.com',
      'https://key@example.com/v1',
      'https://example.com?key=secret',
      'file:///tmp/api',
      'https://example.com/#key',
    ]) {
      expect(
        () => TranslationSettings(baseUrl: url).validate(),
        throwsFormatException,
      );
    }
    expect(
      const TranslationSettings(baseUrl: 'http://localhost:8080/v1/')
          .endpoint
          .path,
      '/v1/chat/completions',
    );
    expect(
      const TranslationSettings(baseUrl: 'http://[::1]:8080').endpoint.host,
      '::1',
    );
    expect(
      const TranslationSettings(
        baseUrl: 'https://example.com/v1/chat/completions',
      ).endpoint.path,
      '/v1/chat/completions',
    );
  });

  test(
    'settings persist UTF-8, replace existing file and never store credentials',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'echopane-settings-',
      );
      final file = File('${directory.path}/translation.json');
      final store = FileSettingsStore(path: file.path);
      try {
        await store.write(const TranslationSettings());
        await store.write(
          const TranslationSettings(target: 'ja', model: 'test-model'),
        );
        expect((await store.read()).target, 'ja');
        final json = jsonDecode(await file.readAsString(encoding: utf8)) as Map;
        expect(json.containsKey('apiKey'), isFalse);
        expect(json.containsKey('enabled'), isFalse);
        expect((await file.readAsBytes()).take(3), isNot([239, 187, 191]));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'latest OCR wins, stopped work cannot publish, cache is session-local',
    () async {
      final capture = CaptureController(FakePlatform());
      await capture.initialize();
      final models = OcrModelStore(directory: 'unused')
        ..phase = ModelPhase.ready;
      final ocr = OcrController(
        capture,
        models,
        FakeOcr(),
        firstDelay: Duration.zero,
      );
      final provider = FakeTranslations();
      final credentials = MemoryCredentials()..key = 'test-key';
      final controller = TranslationController(
        ocr,
        provider,
        MemorySettings(),
        credentials,
        debounce: Duration.zero,
      );
      await controller.initialize();
      await capture.start();
      await ocr.poll();
      expect(controller.enabled, isFalse);
      controller.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 1);
      ocr.lines = [const OcrLine('New text', 0.99)];
      ocr.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.first.cancelled, isTrue);
      expect(
        provider.requests.length,
        1,
        reason: 'Drain cancelled work before starting new request',
      );
      provider.requests.first.completer.complete(['旧译文']);
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 2);
      expect(controller.translations, isEmpty);
      provider.requests[1].completer.complete(['新译文']);
      await Future<void>.delayed(Duration.zero);
      expect(controller.translations, ['新译文']);
      ocr.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 2);
      ocr.lines = [const OcrLine('Other text', 0.99)];
      ocr.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      await capture.stop();
      provider.requests.last.completer.complete(['停止后的译文']);
      await Future<void>.delayed(Duration.zero);
      expect(controller.originals, isEmpty);
      expect(controller.translations, isEmpty);
      await capture.start();
      ocr.lines = [const OcrLine('New text', 0.99)];
      ocr.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 4);
      provider.requests.last.completer.complete(['新会话译文']);
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      ocr.dispose();
      models.dispose();
      await capture.stop();
      capture.dispose();
    },
  );

  test(
    'failed translation keeps originals and retries only on user action',
    () async {
      final capture = CaptureController(FakePlatform());
      await capture.initialize();
      final models = OcrModelStore(directory: 'unused')
        ..phase = ModelPhase.ready;
      final ocr = OcrController(
        capture,
        models,
        FakeOcr(),
        firstDelay: Duration.zero,
      );
      final provider = FakeTranslations();
      final controller = TranslationController(
        ocr,
        provider,
        MemorySettings(),
        MemoryCredentials()..key = 'test-key',
        debounce: Duration.zero,
      );
      await controller.initialize();
      await capture.start();
      await ocr.poll();
      controller.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      provider.requests.single.completer.completeError(
        const TranslationFailure('余额不足'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, TranslationPhase.failed);
      expect(controller.originals, isNotEmpty);
      ocr.notifyListeners();
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 1);
      controller.retry();
      await Future<void>.delayed(Duration.zero);
      expect(provider.requests.length, 2);
      provider.requests.last.completer.complete(['译文']);
      await Future<void>.delayed(Duration.zero);
      expect(controller.phase, TranslationPhase.ready);
      controller.dispose();
      ocr.dispose();
      models.dispose();
      await capture.stop();
      capture.dispose();
    },
  );

  test('changing service host drops old key and failed credential save rolls back settings', () async {
    final capture = CaptureController(FakePlatform());
    final models = OcrModelStore(directory: 'unused');
    final ocr = OcrController(capture, models, FakeOcr());
    final store = MemorySettings();
    final credentials = MemoryCredentials()..key = 'old-key';
    final controller = TranslationController(
      ocr,
      FakeTranslations(),
      store,
      credentials,
    );
    await controller.initialize();
    await controller.configure(
      const TranslationSettings(baseUrl: 'https://another.example.com'),
    );
    expect(credentials.key, isNull);
    expect(controller.hasKey, isFalse);
    credentials.fail = true;
    await expectLater(
      controller.configure(const TranslationSettings(), newKey: 'new-key'),
      throwsA(isA<TranslationFailure>()),
    );
    expect(store.value.baseUrl, 'https://another.example.com');
    expect(controller.settings.baseUrl, store.value.baseUrl);
    expect(controller.enabled, isFalse);
    controller.dispose();
    ocr.dispose();
    models.dispose();
    capture.dispose();
  });
}
