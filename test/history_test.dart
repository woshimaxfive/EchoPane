import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:echopane/history/caption_history.dart';
import 'package:echopane/history/history_dialog.dart';
import 'package:echopane/history/history_exporter.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/translation/provider.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

class TestCaptions extends CaptionSource {
  @override
  bool captionRunning = true;
  @override
  String? captionError;
  @override
  List<String> captionLines = [];
  @override
  String captionSession = '1';
  @override
  int captionRevision = 0;
  @override
  int? get captionDisplayId => null;
  @override
  String get waitingCaption => 'Waiting';
  void emit(List<String> lines) {
    captionLines = lines;
    notifyListeners();
  }
}

class _Fixture {
  _Fixture({int maxEntries = 1000, int maxCharacters = 1000000}) {
    translation = TranslationController(
      source,
      provider,
      MemorySettings(),
      MemoryCredentials()..key = 'unit-test-only',
      debounce: Duration.zero,
    );
    history = CaptionHistory(
      source,
      translation,
      maxEntries: maxEntries,
      maxCharacters: maxCharacters,
      now: () => DateTime.utc(2026, 10, 9),
      origin: () => RecognitionMode.audio,
    );
  }
  final source = TestCaptions();
  final provider = FakeTranslations();
  late final TranslationController translation;
  late final CaptionHistory history;
  Future<void> enable() async {
    await translation.initialize();
    translation.setEnabled(true);
  }

  void dispose() {
    history.dispose();
    translation.dispose();
    source.dispose();
  }
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 10));

class _Exporter implements HistoryExporter {
  final pending = Completer<String?>();
  CaptionSnapshot? received;
  HistoryFormat? format;
  @override
  Future<String?> save(CaptionSnapshot snapshot, HistoryFormat format) {
    received = snapshot;
    this.format = format;
    return pending.future;
  }
}

void main() {
  test(
    'separate identical speech segments survive while meter polls deduplicate',
    () {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.source.emit(['Yes']);
      f.source.emit(['Yes']);
      expect(f.history.length, 1);
      f.source.captionRevision++;
      f.source.emit(['Yes']);
      expect(f.history.length, 2);
      f.history.clear();
      f.source.emit(['Yes']);
      expect(f.history.length, 0);
      f.source.captionRevision++;
      f.source.emit(['Yes']);
      expect(f.history.length, 1);
    },
  );
  test(
    'polling deduplicates, translation pairs, stopping retains history',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.enable();
      f.source.emit(['Hello.', '明日会いましょう。']);
      await _flush();
      for (var i = 0; i < 30; i++) {
        f.source.emit(List.of(f.source.captionLines));
      }
      expect(f.history.length, 1);
      expect(f.history.entries.single.translations, isEmpty);
      final before = f.history.snapshot();
      f.provider.requests.single.completer.complete(['你好。', '明天见。']);
      await _flush();
      expect(f.history.entries.single.translations, ['你好。', '明天见。']);
      expect(f.history.entries.single.target, 'zh-Hans');
      expect(f.history.entries.single.origin, RecognitionMode.audio);
      expect(before.entries.single.translations, isEmpty);
      f.translation.setEnabled(false);
      f.source.captionRunning = false;
      f.source.emit([]);
      expect(f.history.entries.single.translations, ['你好。', '明天见。']);
      expect(() => before.entries.clear(), throwsUnsupportedError);
      expect(
        () => before.entries.single.originals.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'late translation never attaches across renewed or stopped sessions',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.enable();
      f.source.emit(['Same']);
      await _flush();
      final old = f.provider.requests.single;
      f.source.captionSession = '2';
      f.source.emit(['Same']);
      await _flush();
      old.completer.complete(['旧译文']);
      await _flush();
      expect(f.history.length, 2);
      expect(f.history.entries.every((e) => e.translations.isEmpty), true);
      expect(f.provider.requests.length, 2);
      f.provider.requests.last.completer.complete(['新译文']);
      await _flush();
      expect(f.history.entries.first.translations, isEmpty);
      expect(f.history.entries.last.translations, ['新译文']);
      f.source.emit(['Next']);
      await _flush();
      f.source.captionRunning = false;
      f.source.emit([]);
      f.provider.requests.last.completer.complete(['停止后的迟到译文']);
      await _flush();
      expect(f.history.entries.last.translations, isEmpty);
    },
  );

  test('failed translation preserves originals and successful retry updates same entry', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.enable();
    f.source.emit(['A']);
    await _flush();
    f.provider.requests.single.completer.completeError(
      const TranslationFailure('Test failure'),
    );
    await _flush();
    expect(f.history.entries.single.originals, ['A']);
    expect(f.history.entries.single.translations, isEmpty);
    f.translation.retry();
    await _flush();
    f.provider.requests.last.completer.complete(['甲']);
    await _flush();
    expect(f.history.length, 1);
    expect(f.history.entries.single.translations, ['甲']);
  });

  test('clear suppresses current caption and pending translation until input changes', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    await f.enable();
    f.source.emit(['A']);
    await _flush();
    f.history.clear();
    f.source.emit(['A']);
    f.provider.requests.single.completer.complete(['甲']);
    await _flush();
    expect(f.history.length, 0);
    f.source.emit(['B']);
    expect(f.history.length, 1);
    f.source.emit([]);
    f.source.emit(['B']);
    expect(f.history.length, 2);
  });

  test(
    'entry and character limits evict oldest, oversized input is suppressed',
    () {
      final f = _Fixture(maxEntries: 2, maxCharacters: 6);
      addTearDown(f.dispose);
      f.source.emit(['AA']);
      f.source.emit(['BB']);
      f.source.emit(['CC']);
      expect(f.history.entries.map((e) => e.originals.single), ['BB', 'CC']);
      expect(f.history.dropped, 1);
      f.source.emit(['Too large']);
      expect(f.history.length, 0);
      expect(f.history.characters, 0);
      expect(f.history.dropped, 4);
      f.source.emit(['Too large']);
      expect(f.history.dropped, 4);
      f.source.emit(['D']);
      expect(f.history.length, 1);
      f.history.clear();
      expect(f.history.dropped, 0);
    },
  );

  test(
    'translation growth is included in memory bound without repeated insertion',
    () async {
      final f = _Fixture(maxCharacters: 4);
      addTearDown(f.dispose);
      await f.enable();
      f.source.emit(['A']);
      await _flush();
      f.provider.requests.single.completer.complete(['译文太长了']);
      await _flush();
      expect(f.history.length, 0);
      expect(f.history.dropped, 1);
      f.source.emit(['A']);
      expect(f.history.dropped, 1);
    },
  );

  test(
    'real bilingual TXT/JSON export uses UTF-8 and Chinese file paths',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      await f.enable();
      f.source.emit(['Leave.', 'またね。']);
      await _flush();
      f.provider.requests.single.completer.complete(['出发。', '再见。']);
      await _flush();
      final folder = await Directory.systemTemp.createTemp('echopane-export-');
      addTearDown(() => folder.delete(recursive: true));
      for (final format in HistoryFormat.values) {
        final extension = format == HistoryFormat.json ? 'json' : 'txt';
        final path = '${folder.path}/字幕记录.$extension';
        final exporter = DesktopHistoryExporter(
          choosePath: (name, ext) async {
            expect(ext, extension);
            expect(name.endsWith('.$extension'), true);
            return path;
          },
        );
        expect(await exporter.save(f.history.snapshot(), format), path);
        final bytes = await File(path).readAsBytes();
        expect(bytes.take(3), isNot([239, 187, 191]));
        final text = utf8.decode(bytes);
        expect(text, contains('またね。'));
        expect(text, contains('再见。'));
        expect(text, isNot(contains('unit-test-only')));
        if (format == HistoryFormat.json) {
          final data = jsonDecode(text) as Map;
          expect(data['timeBasis'], 'caption_received');
          expect(data['entries'][0]['target'], 'zh-Hans');
          expect(data['entries'][0]['translations'], ['出发。', '再见。']);
        } else {
          expect(text.indexOf('Leave.'), lessThan(text.indexOf('出发。')));
        }
      }
      final cancelled = DesktopHistoryExporter(
        choosePath: (_, _) async => null,
      );
      expect(
        await cancelled.save(f.history.snapshot(), HistoryFormat.text),
        isNull,
      );
      expect(folder.listSync().length, 2);
    },
  );

  test(
    'file failures propagate without changing the in-memory history',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.source.emit(['A']);
      final folder = await Directory.systemTemp.createTemp(
        'echopane-failed-export-',
      );
      addTearDown(() => folder.delete(recursive: true));
      final exporter = DesktopHistoryExporter(
        choosePath: (_, _) async => '${folder.path}/missing/file.txt',
      );
      await expectLater(
        exporter.save(f.history.snapshot(), HistoryFormat.text),
        throwsA(isA<FileSystemException>()),
      );
      expect(f.history.length, 1);
    },
  );

  testWidgets(
    'history dialog fits minimum window, copies, snapshots export and clears',
    (tester) async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.source.emit(['English text', '明日の朝。']);
      final exporter = _Exporter();
      tester.view.reset();
      tester.view.physicalSize = const Size(680, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showCaptionHistory(context, f.history, exporter: exporter),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('history-copy-all')));
      await tester.pumpAndSettle();
      expect(copied, contains('明日の朝。'));
      await tester.tap(find.byKey(const Key('history-export')));
      await tester.pump();
      expect(exporter.received!.entries.length, 1);
      f.source.emit(['New caption']);
      await tester.pump();
      expect(exporter.received!.entries.length, 1);
      exporter.pending.complete(null);
      await tester.pumpAndSettle();
      expect(find.text('已导出到所选文件。'), findsNothing);
      await tester.tap(find.byKey(const Key('history-clear')));
      await tester.pumpAndSettle();
      expect(f.history.length, 0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('history-close')));
      await tester.pumpAndSettle();
    },
  );
}
