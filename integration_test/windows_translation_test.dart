import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/capture/capture_platform.dart';
import 'package:echopane/translation/settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'screen OCR to bilingual captions, settings and Windows credentials',
    (tester) async {
      const manifestPath = String.fromEnvironment('ECHO_OCR_FIXTURES');
      const artifacts = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      expect(manifestPath, isNotEmpty);
      final fixtures = jsonDecode(
        await File(manifestPath).readAsString(encoding: utf8),
      ) as List;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final folder = await Directory.systemTemp.createTemp(
        'echopane-translation-',
      );
      int status = 200;
      int calls = 0;
      final subscription = server.listen((request) async {
        try {
          expectSync(request.uri.path, '/v1/chat/completions');
          expectSync(
            request.headers.value('authorization'),
            'Bearer integration-test-only',
          );
          final body = jsonDecode(await utf8.decodeStream(request)) as Map;
          expectSync(body.containsKey('tools'), isFalse);
          final message = (body['messages'] as List)[1] as Map;
          final segments =
              (jsonDecode(message['content'] as String) as Map)['segments']
                  as List;
          expectSync(
            segments.every(
              (segment) => (segment as Map).keys.toSet().difference({
                'id',
                'text',
              }).isEmpty,
            ),
            isTrue,
          );
          calls++;
          request.response.statusCode = status;
          if (status == 200) {
            String translate(String text) {
              if (text.contains('sunrise')) return '我们得在日出前离开。';
              if (text.contains('road')) return '这条路仍然畅通。';
              if (text.contains('明日')) return '明天早上我们在这里见面吧。';
              if (text.contains('新しい')) return '一起开始新的旅程吧。';
              if (text.contains('Hello')) return '你好，世界。';
              return '测试译文';
            }

            request.response.headers.contentType = ContentType(
              'application',
              'json',
              charset: 'utf-8',
            );
            request.response.write(
              jsonEncode({
                'choices': [
                  {
                    'finish_reason': 'stop',
                    'message': {
                      'content': jsonEncode({
                        'translations': [
                          for (final item in segments.reversed)
                            {
                              'id': item['id'],
                              'text': translate(item['text'] as String),
                            },
                        ],
                      }),
                    },
                  },
                ],
              }),
            );
          } else {
            request.response.write('Do not show raw provider response');
          }
          await request.response.close();
        } catch (error) {
          debugPrint('Local fixture handler failed: $error');
          await request.response.close();
        }
      });
      const credentials = WindowsCredentialStore(testing: true);
      final store = FileSettingsStore(path: '${folder.path}/translation.json');
      Future<void> screenshot(String name) async {
        if (artifacts.isEmpty) return;
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('window-content')),
        );
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$artifacts/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      await app.startApplication(
        settingsStore: store,
        credentials: credentials,
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final capture = window.controller;
      final ocr = window.ocr!;
      final translation = window.translation!;
      const channel = WindowsCapturePlatform.channel;
      try {
        await credentials.delete();
        await credentials.write('测试_key_本机');
        expect(await credentials.read(), '测试_key_本机');
        await credentials.delete();
        expect(await credentials.read(), isNull);
        expect(translation.enabled, isFalse);
        expect(capture.running, isFalse);
        await tester.tap(find.byKey(const Key('translation-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('translation-service')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('阿里云百炼 · DeepSeek Flash').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('translation-url')))
              .controller!
              .text,
          'https://dashscope.aliyuncs.com/compatible-mode/v1',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('translation-model')))
              .controller!
              .text,
          'deepseek-v4-flash',
        );
        await tester.tap(find.byKey(const Key('translation-service')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义兼容服务').last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('translation-url')),
          'http://127.0.0.1:${server.port}/v1',
        );
        await tester.enterText(
          find.byKey(const Key('translation-model')),
          'local-protocol-fixture',
        );
        await tester.enterText(
          find.byKey(const Key('translation-key')),
          'integration-test-only',
        );
        await tester.tap(find.byKey(const Key('translation-save')));
        await tester.pumpAndSettle();
        expect(translation.hasKey, isTrue);
        expect(translation.enabled, isFalse);
        expect((await store.read()).model, 'local-protocol-fixture');
        expect(
          await File(store.path).readAsString(encoding: utf8),
          isNot(contains('integration-test-only')),
        );
        for (int i = 0; i < 100 && !ocr.ready; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
        }
        expect(ocr.ready, isTrue);
        final fixture =
            fixtures.firstWhere((value) => value['name'] == 'english') as Map;
        final region = await channel.invokeMapMethod<Object?, Object?>(
          'debugCreateFixture',
          {
            'path': fixture['path'],
            'width': fixture['width'],
            'height': fixture['height'],
          },
        );
        await capture.chooseDisplay(capture.displays.first);
        capture.region = CaptureRegion.fromMap(region!);
        final elapsed = Stopwatch()..start();
        await capture.start();
        await tester.pump();
        await tester.tap(find.byKey(const Key('translation-toggle')));
        for (
          int i = 0;
          i < 120 && translation.phase != TranslationPhase.ready;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
        }
        expect(translation.error, isNull);
        expect(translation.translations, ['我们得在日出前离开。', '这条路仍然畅通。']);
        await tester.pump();
        expect(find.text('我们得在日出前离开。'), findsOneWidget);
        final firstLatency = elapsed.elapsedMilliseconds;
        await screenshot('bilingual-window');
        final count = calls;
        await tester.pump(const Duration(milliseconds: 1200));
        expect(
          calls,
          count,
          reason: 'Static captions do not repeat paid requests',
        );
        status = 401;
        translation.retry();
        for (
          int i = 0;
          i < 80 && translation.phase != TranslationPhase.failed;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(translation.originals, isNotEmpty);
        expect(translation.translations, isEmpty);
        expect(translation.error, contains('API Key'));
        final errors = calls;
        await tester.pump(const Duration(milliseconds: 1000));
        expect(calls, errors);
        status = 200;
        await tester.tap(find.text('重试翻译'));
        for (
          int i = 0;
          i < 80 && translation.phase != TranslationPhase.ready;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(translation.phase, TranslationPhase.ready);
        final japanese =
            fixtures.firstWhere((value) => value['name'] == 'japanese') as Map;
        await channel.invokeMethod<void>('debugUpdateFixture', {
          'path': japanese['path'],
          'width': japanese['width'],
          'height': japanese['height'],
        });
        for (
          int i = 0;
          i < 120 &&
              !translation.translations.any((text) => text.contains('明天'));
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await ocr.poll();
        }
        expect(translation.translations.first, contains('明天'));
        expect(translation.translations, isNot(contains('我们得在日出前离开。')));
        expect(
          window.history!.entries.any(
            (entry) => entry.translations.contains('我们得在日出前离开。'),
          ),
          true,
        );
        expect(
          window.history!.entries.any(
            (entry) => entry.translations.any((text) => text.contains('明天')),
          ),
          true,
        );
        final historyCount = window.history!.length;
        await capture.stop();
        await tester.pump(const Duration(milliseconds: 500));
        expect(translation.originals, isEmpty);
        expect(translation.translations, isEmpty);
        expect(window.history!.length, historyCount);
        await windowManager.setSize(const Size(680, 520));
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('translation-settings')));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Settings fit minimum window',
        );
        await tester.tap(find.text('测试连接'));
        await tester.pumpAndSettle();
        expect(find.text('测试成功：你好，世界。'), findsOneWidget);
        await tester.tap(find.text('删除 Key'));
        await tester.pumpAndSettle();
        expect(await credentials.read(), isNull);
        expect(translation.hasKey, isFalse);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await windowManager.setSize(const Size(900, 720));
        if (artifacts.isNotEmpty) {
          await File('$artifacts/translation-results.json').writeAsString(
            jsonEncode({
              'service':
                  'Local protocol fixture; not a real translation quality test',
              'requests': calls,
              'firstScreenToBilingualMs': firstLatency,
              'windowsCredentialRoundtrip': true,
              'configContainsKey': false,
              'staticDeduplication': true,
              'failureRetry': true,
              'minimumSize': '680x520',
            }),
            encoding: utf8,
          );
        }
      } finally {
        await capture.stop();
        translation.setEnabled(false);
        translation.cancelTest();
        await channel.invokeMethod<void>('debugDestroyFixture');
        await credentials.delete();
        await subscription.cancel();
        await server.close(force: true);
        await folder.delete(recursive: true);
      }
    },
  );
}
