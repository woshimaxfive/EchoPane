import 'package:echopane/ocr/ocr_controller.dart';
import 'package:echopane/ocr/text_blocks.dart';
import 'package:echopane/screen_translation/screen_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'wrapped question is translated as a complete block below both lines',
    () {
      final blocks = groupTextBlocks([
        const OcrLine(
          'Question 19. What does the speaker say about people not',
          0.98,
          bounds: Rect.fromLTWH(34, 115, 1260, 44),
        ),
        const OcrLine(
          'taking any vacation?',
          0.99,
          bounds: Rect.fromLTWH(435, 178, 449, 44),
        ),
      ]);
      expect(blocks, hasLength(1));
      expect(
        blocks.single.text,
        'Question 19. What does the speaker say about people not taking any vacation?',
      );
      expect(blocks.single.lineHeight, 44);
      final placed = layoutScreenTranslations(
        size: const Size(1392, 390),
        lines: blocks,
        translations: ['问题19：说话者对那些不休假的人有什么看法？'],
        mode: ScreenTranslationMode.below,
      );
      expect(placed, hasLength(1));
      expect(placed.single.bounds.top, greaterThan(222));
      expect(placed.single.text, contains('说话者'));
      expect(placed.single.fontSize, 33);
    },
  );
  test(
    'columns, labels, completed sentences and numbered options remain separate',
    () {
      List<OcrLine> pair(
        String a,
        String b, {
        double x = 20,
        double height = 30,
      }) => [
        OcrLine(a, 1, bounds: const Rect.fromLTWH(20, 20, 200, 30)),
        OcrLine(b, 1, bounds: Rect.fromLTWH(x, 55, 200, height)),
      ];
      for (final lines in [
        pair('First complete sentence.', 'Second complete sentence.'),
        pair('Settings', 'Help'),
        pair('A long incomplete sentence', 'Other column text', x: 300),
        pair('A long incomplete sentence', 'B. Another answer'),
        pair('A long incomplete sentence', 'a much smaller label', height: 12),
      ]) {
        expect(groupTextBlocks(lines), hasLength(2));
      }
    },
  );
  test('dense Chinese prose merges but short menu items do not', () {
    final text = groupTextBlocks([
      const OcrLine(
        '这是一段没有结束的连续中文内容',
        1,
        bounds: Rect.fromLTWH(10, 10, 200, 30),
      ),
      const OcrLine('接下来继续说明这个问题。', 1, bounds: Rect.fromLTWH(10, 47, 200, 30)),
    ]);
    expect(text, hasLength(1));
  });

  test(
    'a tight original crop places the entire translation outside OCR input',
    () {
      final placed = layoutScreenTranslations(
        size: const Size(400, 500),
        lines: [
          const OcrLine(
            'A complete source sentence.',
            1,
            bounds: Rect.fromLTWH(10, 10, 350, 40),
          ),
        ],
        translations: ['这是完整译文'],
        mode: ScreenTranslationMode.below,
        belowMinimum: 62,
      );
      expect(placed.single.bounds.top, 62);
      expect(placed.single.bounds.bottom, lessThan(500));
    },
  );
  test(
    'text that cannot fit below is reported as unplaced, never partly clipped',
    () {
      final placed = layoutScreenTranslations(
        size: const Size(200, 100),
        lines: [
          const OcrLine('Source', 1, bounds: Rect.fromLTWH(0, 40, 100, 45)),
        ],
        translations: [List.filled(50, '很长的内容').join()],
        mode: ScreenTranslationMode.below,
      );
      expect(placed, isEmpty);
    },
  );
}
