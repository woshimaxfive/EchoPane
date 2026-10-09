import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ocr/ocr_controller.dart';

enum ScreenTranslationMode { below, replace }

class PositionedTranslation {
  const PositionedTranslation(
    this.text,
    this.bounds,
    this.fontSize,
    this.background,
  );
  final String text;
  final Rect bounds;
  final double fontSize;
  final Color background;
}

/// Coordinates stay in physical capture pixels; monitor DPI is not applied twice.
List<PositionedTranslation> layoutScreenTranslations({
  required Size size,
  required List<OcrLine> lines,
  required List<String> translations,
  required ScreenTranslationMode mode,
  double fontScale = 1,
}) {
  if (lines.length != translations.length) return [];
  final screen = Offset.zero & size;
  final placed = <PositionedTranslation>[];
  for (int i = 0; i < lines.length; i++) {
    final source = lines[i].bounds;
    if (!source.isFinite ||
        source.width <= 0 ||
        source.height <= 0 ||
        translations[i].trim().isEmpty) {
      continue;
    }
    final original = source.intersect(screen);
    if (original.isEmpty) continue;
    final font = (source.height * 0.75 * fontScale).clamp(10.0, 64.0);
    Rect area;
    if (mode == ScreenTranslationMode.replace) {
      area = original.inflate(2).intersect(screen);
    } else {
      final width = original.width.clamp(
        size.width < 80 ? size.width : 80.0,
        size.width,
      );
      final left = original.left.clamp(0.0, size.width - width);
      final top = original.bottom + 2;
      double bottom = (top + source.height * 1.5 + 8).clamp(0.0, size.height);
      for (final other in lines) {
        final box = other.bounds;
        if (box.top >= top && box.left < left + width && box.right > left) {
          bottom = bottom.clamp(top, box.top - 2 < top ? top : box.top - 2);
        }
      }
      if (bottom - top < 10) continue;
      area = Rect.fromLTRB(left, top, left + width, bottom).intersect(screen);
      // Never cover original words or earlier translations in bilingual mode.
      if (lines.any((line) => line.bounds.overlaps(area)) ||
          placed.any((item) => item.bounds.overlaps(area))) {
        continue;
      }
    }
    placed.add(
      PositionedTranslation(
        translations[i],
        area,
        font,
        Color(lines[i].background),
      ),
    );
  }
  return placed;
}

Future<ui.Image> renderScreenTranslations({
  required int width,
  required int height,
  required List<PositionedTranslation> blocks,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final block in blocks) {
    canvas.save();
    canvas.clipRect(block.bounds);
    canvas.drawRect(block.bounds, Paint()..color = block.background);
    final luminance = block.background.computeLuminance();
    final color = luminance > 0.35 ? Colors.black : Colors.white;
    final inner = block.bounds.deflate(2);
    if (inner.width <= 0 || inner.height <= 0) {
      canvas.restore();
      continue;
    }
    double font = block.fontSize;
    TextPainter painter;
    while (true) {
      painter = TextPainter(
        text: TextSpan(
          text: block.text,
          style: TextStyle(
            color: color,
            fontSize: font,
            height: 1.1,
            fontFamily: 'Microsoft YaHei',
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
      )..layout(maxWidth: inner.width);
      if (painter.height <= inner.height || font <= 8) break;
      painter.dispose();
      font = (font - 1).clamp(8.0, 64.0);
    }
    painter.paint(
      canvas,
      Offset(
        inner.left,
        inner.top +
            ((inner.height - painter.height) / 2).clamp(0.0, inner.height),
      ),
    );
    painter.dispose();
    canvas.restore();
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}
