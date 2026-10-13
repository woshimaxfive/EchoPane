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
  final groups = <List<OcrLine>>[];
  bool prose(String text) =>
      text.trim().split(RegExp(r'\s+')).length >= 3 ||
      RegExp(r'[一-鿿ぁ-ヿ]').allMatches(text).length >= 10;
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

  for (final line in ordered) {
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
  return [
    for (final group in groups)
      if (group.length == 1)
        group.single
      else
        OcrLine(
          group.map((line) => line.text.trim()).join(' '),
          group.map((line) => line.confidence).reduce(math.min),
          bounds: group
              .map((line) => line.bounds)
              .reduce((a, b) => a.expandToInclude(b)),
          background: group.first.background,
          sourceLineHeight: group
              .map((line) => line.lineHeight)
              .reduce(math.max),
        ),
  ];
}
