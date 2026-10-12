import 'package:echopane/subtitles/audio_presentation.dart';
import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_renderer.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<SubtitleRow> frame(
  AudioSubtitlePresentation presentation,
  int milliseconds, {
  double width = 720,
  double height = 220,
  OverlaySettings settings = const OverlaySettings(),
}) => presentation.layout(
  width: width,
  height: height,
  settings: settings,
  locked: false,
  now: Duration(milliseconds: milliseconds),
);
List<String> texts(List<SubtitleRow> rows) => rows.map((r) => r.text).toList();

void fits(List<SubtitleRow> rows, double width, OverlaySettings settings) {
  for (final row in rows) {
    final painter = TextPainter(
      text: TextSpan(
        text: row.text,
        style: subtitleTextStyle(settings, row.secondary),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width - 40);
    expect(painter.didExceedMaxLines, false, reason: row.text);
    painter.dispose();
    expect(row.text, isNot(contains('…')));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'uninterrupted long speech rolls measured lines instead of ellipsizing',
    () {
      const settings = OverlaySettings(
        mode: SubtitleMode.translated,
        maxLines: 2,
      );
      const long =
          '第一部分我们正在沿着这条道路前进沿途可以看到许多树木和房屋'
          '接着我们会穿过广场到达目的地请大家留意身边的变化最后这是结尾';
      final presentation = AudioSubtitlePresentation();
      presentation.update([
        const CaptionTurn('1', 'Continuous speech', long, false),
      ], Duration.zero);
      final first = frame(presentation, 0, width: 400, settings: settings);
      expect(texts(first).join(), startsWith('第一部分'));
      expect(first.length, lessThanOrEqualTo(2));
      fits(first, 400, settings);
      final seen = <String>{...texts(first)};
      for (var time = 4100; time <= 41000; time += 4100) {
        final rows = frame(presentation, time, width: 400, settings: settings);
        fits(rows, 400, settings);
        seen.addAll(texts(rows));
      }
      expect(seen.join(), contains('结尾'));
      expect(seen.length, greaterThan(first.length));
    },
  );

  test('new turn does not erase a translation that just completed', () {
    final presentation = AudioSubtitlePresentation();
    presentation.update([
      const CaptionTurn('1', 'First.', '第一句。', false),
    ], Duration.zero);
    frame(presentation, 0);
    presentation.update([
      const CaptionTurn('1', 'First.', '第一句完整译文。', true),
      const CaptionTurn('2', 'Second.', '第二句。', false),
    ], const Duration(milliseconds: 100));
    expect(texts(frame(presentation, 100)), containsAll(['第一句完整译文。', '第二句。']));
    expect(texts(frame(presentation, 1000)), contains('第一句完整译文。'));
    expect(texts(frame(presentation, 5100)), isNot(contains('第一句完整译文。')));
  });

  test('late final revises its older slot without replacing newer speech', () {
    final presentation = AudioSubtitlePresentation();
    presentation.update([
      const CaptionTurn('1', 'First', '临时错误', false),
    ], Duration.zero);
    frame(presentation, 0);
    presentation.update([
      const CaptionTurn('1', 'First', '临时错误', false),
      const CaptionTurn('2', 'Second', '新的话', false),
    ], const Duration(milliseconds: 500));
    frame(presentation, 500);
    presentation.update([
      const CaptionTurn('1', 'First', '更正后的完整译文', true),
      const CaptionTurn('2', 'Second', '新的话', false),
    ], const Duration(milliseconds: 3000));
    final rows = texts(frame(presentation, 3000));
    expect(rows, containsAll(['更正后的完整译文', '新的话']));
    expect(rows, isNot(contains('临时错误')));
    expect(texts(frame(presentation, 4000)), contains('更正后的完整译文'));
  });

  test('identical snapshots do not extend reading time or duplicate turns', () {
    final presentation = AudioSubtitlePresentation();
    const turns = [
      CaptionTurn('1', 'A', '你好', true),
      CaptionTurn('2', 'B', '再见', false),
    ];
    presentation.update([turns.first], Duration.zero);
    frame(presentation, 0);
    for (var time = 100; time <= 5000; time += 100) {
      presentation.update(turns, Duration(milliseconds: time));
      frame(presentation, time);
    }
    expect(texts(frame(presentation, 5000)), ['B', '再见']);
  });

  test(
    'bilingual narrow window keeps translations visible and measures Unicode',
    () {
      final presentation = AudioSubtitlePresentation();
      presentation.update([
        const CaptionTurn(
          '1',
          'A long English sentence with emoji 👩🏽‍💻 and words.',
          '明日の朝ここで会いましょう这是中文测试。',
          false,
        ),
      ], Duration.zero);
      for (final width in [240.0, 400.0, 1000.0]) {
        final rows = frame(presentation, 0, width: width, height: 180);
        expect(rows.any((r) => !r.secondary), true);
        fits(rows, width, const OverlaySettings());
        expect(rows.length, lessThanOrEqualTo(3));
        for (final row in rows) {
          expect(row.text.runes.any((r) => r >= 0xd800 && r <= 0xdfff), false);
        }
      }
    },
  );

  test(
    'overflow advances toward recent turns and does not resurrect evicted text',
    () {
      final presentation = AudioSubtitlePresentation();
      final turns = <CaptionTurn>[];
      for (var i = 0; i < 12; i++) {
        turns.add(CaptionTurn('$i', 'source$i', '译文$i', false));
        presentation.update(turns, Duration(milliseconds: i * 100));
        frame(presentation, i * 100);
      }
      final rows = texts(frame(presentation, 1200));
      expect(rows, isNot(contains('译文0')));
      expect(rows, contains('译文8'));
      presentation.update(turns, const Duration(seconds: 20));
      expect(texts(frame(presentation, 20000)), isNot(contains('译文0')));
    },
  );

  test(
    'very long completed turn cannot indefinitely delay following speech',
    () {
      final presentation = AudioSubtitlePresentation();
      final long = List.filled(30, '这是一个很长的连续讲话内容').join();
      presentation.update([
        CaptionTurn('1', 'Long', long, false),
      ], Duration.zero);
      frame(presentation, 0);
      presentation.update([
        CaptionTurn('1', 'Long', long, true),
        const CaptionTurn('2', 'Next', '下一句', false),
      ], const Duration(seconds: 1));
      for (var time = 1000; time <= 12000; time += 100) {
        frame(presentation, time);
      }
      expect(texts(frame(presentation, 12000)), ['Next', '下一句']);
    },
  );

  test('reset and reopening start at current speech with no stale queue', () {
    final presentation = AudioSubtitlePresentation();
    presentation.update([
      const CaptionTurn('old', 'Old', '旧字幕', true),
    ], Duration.zero);
    frame(presentation, 0);
    presentation.reset();
    expect(frame(presentation, 100), isEmpty);
    presentation.update([
      const CaptionTurn('old', 'Old', '旧字幕', true),
      const CaptionTurn('new', 'New', '新字幕', false),
    ], const Duration(milliseconds: 100));
    expect(texts(frame(presentation, 100)), ['New', '新字幕']);
  });

  test('display modes preserve language separation and shorter text expires earlier', () {
    for (final mode in [SubtitleMode.original, SubtitleMode.translated]) {
      final presentation = AudioSubtitlePresentation();
      presentation.update([
        const CaptionTurn('1', 'Original', '译文', true),
      ], Duration.zero);
      final rows = texts(
        frame(presentation, 0, settings: OverlaySettings(mode: mode)),
      );
      expect(rows, mode == SubtitleMode.original ? ['Original'] : ['译文']);
    }
    AudioSubtitlePresentation prepare(String text) {
      final presentation = AudioSubtitlePresentation();
      presentation.update([
        CaptionTurn('1', 'First', text, false),
      ], Duration.zero);
      frame(presentation, 0);
      presentation.update([
        CaptionTurn('1', 'First', text, true),
        const CaptionTurn('2', 'Next', '下一句', false),
      ], const Duration(milliseconds: 100));
      frame(presentation, 100);
      return presentation;
    }

    final short = prepare('短句');
    final long = prepare('这是比较长的一句译文需要更多阅读时间');
    expect(texts(frame(short, 1600)), isNot(contains('短句')));
    expect(texts(frame(long, 1600)).join(), contains('这是比较长'));
  });
}
