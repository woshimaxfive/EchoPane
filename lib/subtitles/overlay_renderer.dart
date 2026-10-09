import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'overlay_settings.dart';

class SubtitleRow {
  const SubtitleRow(this.text, {this.secondary = false});
  final String text;
  final bool secondary;
}

List<SubtitleRow> subtitleRows(
  OverlaySettings settings,
  List<String> originals,
  List<String> translations,
) {
  if (settings.mode == SubtitleMode.translated) {
    return translations.map((value) => SubtitleRow(value)).toList();
  }
  if (settings.mode == SubtitleMode.original ||
      translations.length != originals.length ||
      translations.isEmpty) {
    return originals.map((value) => SubtitleRow(value)).toList();
  }
  return [
    for (int i = 0; i < originals.length; i++) ...[
      SubtitleRow(originals[i], secondary: true),
      SubtitleRow(translations[i]),
    ],
  ];
}

Future<ui.Image> renderSubtitles({
  required int width,
  required int height,
  required double scale,
  required OverlaySettings settings,
  required List<SubtitleRow> rows,
  required bool locked,
  required String status,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  final w = width / scale, h = height / scale;
  final bounds = Rect.fromLTWH(2, 2, w - 4, h - 4);
  canvas.drawRRect(
    RRect.fromRectAndRadius(bounds, const Radius.circular(12)),
    Paint()
      ..color = const Color(0xff101820)
          .withValues(alpha: settings.backgroundOpacity),
  );
  if (!locked) {
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(2, 2, w - 4, 32),
        topLeft: const Radius.circular(12),
        topRight: const Radius.circular(12),
      ),
      Paint()..color = const Color(0xff101820).withValues(alpha: 0.94),
    );
    _paintText(
      canvas,
      '随幕字幕  ·  拖动移动，边缘调整大小',
      13,
      const Color(0xffd4dce3),
      Rect.fromLTWH(16, 8, w - 62, 22),
      1,
      centered: false,
    );
    _paintText(
      canvas,
      '×',
      22,
      Colors.white,
      Rect.fromLTWH(w - 36, 3, 24, 28),
      1,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, const Radius.circular(12)),
      Paint()
        ..color = const Color(0xff708196).withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(w - 18, h - 7),
      Offset(w - 7, h - 18),
      Paint()
        ..color = const Color(0xffd4dce3)
        ..strokeWidth = 1.5,
    );
  }
  final top = locked ? 12.0 : 42.0;
  final available = h - top - 12;
  canvas.save();
  canvas.clipRect(Rect.fromLTWH(14, top, w - 28, available.clamp(0, h)));
  if (rows.isEmpty) {
    _paintText(
      canvas,
      status,
      16,
      const Color(0xffd4dce3),
      Rect.fromLTWH(20, top, w - 40, available),
      2,
    );
  } else {
    final capacity = (available / (settings.fontSize * 1.35)).floor().clamp(
      1,
      settings.maxLines,
    );
    int count = rows.length.clamp(1, capacity);
    // Keep bilingual pairs together when choosing the tail of a long screen.
    if (rows.any((row) => row.secondary) && count > 1 && count.isOdd) count--;
    final selected = rows.skip(rows.length - count).toList();
    final painters = <TextPainter>[];
    int remaining = capacity;
    for (int i = 0; i < selected.length; i++) {
      final row = selected[i];
      final font = row.secondary ? settings.fontSize * 0.72 : settings.fontSize;
      final lineBudget = (remaining - (selected.length - i - 1)).clamp(
        1,
        capacity,
      );
      final painter = TextPainter(
        text: TextSpan(
          text: row.text,
          style: TextStyle(
            fontFamily: 'Segoe UI',
            fontSize: font,
            height: 1.35,
            color: row.secondary ? const Color(0xffd4dce3) : Colors.white,
            fontWeight: row.secondary ? FontWeight.w400 : FontWeight.w600,
            shadows: const [
              Shadow(color: Colors.black, blurRadius: 3, offset: Offset(0, 1)),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: lineBudget,
        ellipsis: '…',
      )..layout(maxWidth: w - 40);
      remaining -= painter.computeLineMetrics().length;
      painters.add(painter);
    }
    final totalHeight =
        painters.fold<double>(0, (sum, painter) => sum + painter.height) +
        (painters.length - 1) * 4;
    double y = top + ((available - totalHeight) / 2).clamp(0, h);
    for (final painter in painters) {
      painter.paint(canvas, Offset((w - painter.width) / 2, y));
      y += painter.height + 4;
      painter.dispose();
    }
  }
  canvas.restore();
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

void _paintText(
  Canvas canvas,
  String text,
  double size,
  Color color,
  Rect rect,
  int maxLines, {
  bool centered = true,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: 'Segoe UI',
        fontSize: size,
        color: color,
        height: 1.35,
      ),
    ),
    textDirection: TextDirection.ltr,
    textAlign: centered ? TextAlign.center : TextAlign.left,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: rect.width);
  painter.paint(
    canvas,
    Offset(
      centered ? rect.left + (rect.width - painter.width) / 2 : rect.left,
      rect.top + ((rect.height - painter.height) / 2).clamp(0, rect.height),
    ),
  );
  painter.dispose();
}
