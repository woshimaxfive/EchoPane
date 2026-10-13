import 'dart:math' as math;

import 'ocr_controller.dart';

/// Join wrapped prose before translation, while retaining independent labels,
/// list items, columns and sentences. Coordinates remain capture pixels.
List<OcrLine> groupTextBlocks(List<OcrLine> input) {
  final ordered = List<OcrLine>.of(input)
    ..sort((a, b) {
      final top = a.bounds.top.compareTo(b.bounds.top);
      return top == 0 ? a.bounds.left.compareTo(b.bounds.left) : top;
    });
  bool prose(String text) =>
      text.trim().split(RegExp(r'\s+')).length >= 3 ||
      RegExp(r'[一-鿿ぁ-ヿ]').allMatches(text).length >= 10;
  OcrLine combine(List<OcrLine> group) => group.length == 1
      ? group.single
      : OcrLine(
          group.map((line) => line.text.trim()).join(' '),
          group.map((line) => line.confidence).reduce(math.min),
          bounds: group
              .map((line) => line.bounds)
              .reduce((a, b) => a.expandToInclude(b)),
          background: group.first.background,
          sourceLines: [
            for (final line in group)
              ...line.sourceLines.isEmpty ? [line] : line.sourceLines,
          ],
          sourceLineHeight: group
              .map((line) => line.lineHeight)
              .reduce(math.max),
        );
  // OCR can split a sentence into several boxes on the same baseline. Restore
  // those rows before deciding whether they also wrap onto the next row.
  final rows = <List<OcrLine>>[];
  for (final line in ordered) {
    final row = rows
        .where(
          (row) =>
              (row.first.bounds.center.dy - line.bounds.center.dy).abs() <=
              math.max(row.first.lineHeight, line.lineHeight) * 0.35,
        )
        .firstOrNull;
    if (row == null) {
      rows.add([line]);
    } else {
      row.add(line);
    }
  }
  final completeRows = <OcrLine>[];
  for (final row in rows) {
    row.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
    final segment = <OcrLine>[];
    for (final line in row) {
      if (segment.isNotEmpty) {
        final previous = segment.last;
        final height = math.max(previous.lineHeight, line.lineHeight);
        final gap = line.bounds.left - previous.bounds.right;
        if (gap < -height * 0.5 ||
            gap > height * 1.5 ||
            RegExp(r'[.!?。！？][”’"\)\]]?$').hasMatch(previous.text.trim()) ||
            math.min(previous.lineHeight, line.lineHeight) / height < 0.75 ||
            !(prose(segment.map((item) => item.text).join(' ')) ||
                prose(line.text))) {
          completeRows.add(combine(segment));
          segment.clear();
        }
      }
      segment.add(line);
    }
    if (segment.isNotEmpty) completeRows.add(combine(segment));
  }
  completeRows.sort((a, b) => a.bounds.top.compareTo(b.bounds.top));
  final groups = <List<OcrLine>>[];
  bool joins(OcrLine a, OcrLine b) {
    final height = math.max(a.lineHeight, b.lineHeight);
    if (height <= 0 ||
        math.min(a.lineHeight, b.lineHeight) / height < 0.75 ||
        RegExp(r'[.!?。！？][”’"\)\]]?$').hasMatch(a.text.trim()) ||
        RegExp(r'^(?:[-•●*]|\(?\d+[.)]|[A-Da-d][.)])\s')
            .hasMatch(b.text.trim()) ||
        !(prose(a.text) || prose(b.text))) {
      return false;
    }
    final gap = b.bounds.top - a.bounds.bottom;
    final overlap =
        math.min(a.bounds.right, b.bounds.right) -
        math.max(a.bounds.left, b.bounds.left);
    return gap >= -height * 0.15 &&
        gap <= height * 0.9 &&
        overlap >= math.min(a.bounds.width, b.bounds.width) * 0.5;
  }

  for (final line in completeRows) {
    List<OcrLine>? target;
    for (final group in groups.reversed) {
      if (group.length < 8 && joins(group.last, line)) {
        target = group;
        break;
      }
    }
    if (target == null) {
      groups.add([line]);
    } else {
      target.add(line);
    }
  }
  return groups.map(combine).toList();
}
