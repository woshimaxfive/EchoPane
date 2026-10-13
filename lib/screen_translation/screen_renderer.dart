import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ocr/ocr_controller.dart';

enum ScreenTranslationMode { below, replace }

class PositionedTranslation {
  const PositionedTranslation(
    this.text,
    this.bounds,
    this.fontSize,
    this.background, {
    this.backdrop,
    this.paintBackground = true,
  });
  final String text;
  final Rect bounds;
  final double fontSize;
  final Color background;
  final OcrBackgroundPatch? backdrop;
  final bool paintBackground;
}

List<String> _distributeTranslation(String text, List<OcrLine> lines) {
  final characters = text.trim().runes.map(String.fromCharCode).toList();
  final width = lines.fold(0.0, (sum, line) => sum + line.bounds.width);
  var start = 0, cumulative = 0.0;
  final segments = <String>[];
  for (var i = 0; i < lines.length; i++) {
    cumulative += lines[i].bounds.width;
    var end = i == lines.length - 1
        ? characters.length
        : (characters.length * cumulative / width).round().clamp(
            start,
            characters.length,
          );
    if (i < lines.length - 1 &&
        end > start &&
        end < characters.length &&
        !RegExp(r'\s').hasMatch(characters[end])) {
      final radius = ((end - start) * 0.35).ceil();
      for (var distance = 1; distance <= radius; distance++) {
        final before = end - distance, after = end + distance;
        if (before > start && RegExp(r'\s').hasMatch(characters[before])) {
          end = before;
          break;
        }
        if (after < characters.length &&
            RegExp(r'\s').hasMatch(characters[after])) {
          end = after;
          break;
        }
      }
    }
    segments.add(characters.sublist(start, end).join().trim());
    start = end;
  }
  return segments;
}

/// Coordinates stay in physical capture pixels; monitor DPI is not applied twice.
List<PositionedTranslation> layoutScreenTranslations({
  required Size size,
  required List<OcrLine> lines,
  required List<String> translations,
  required ScreenTranslationMode mode,
  double fontScale = 1,
  double belowMinimum = 0,
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
    final font = (lines[i].lineHeight * 0.75 * fontScale).clamp(10.0, 64.0);
    Rect area;
    if (mode == ScreenTranslationMode.replace) {
      final sources = lines[i].sourceLines.isEmpty
          ? [lines[i]]
          : lines[i].sourceLines;
      final rows = <List<OcrLine>>[];
      for (final source in sources) {
        final row = rows
            .where(
              (row) =>
                  (row.first.bounds.center.dy - source.bounds.center.dy)
                      .abs() <=
                  row.first.lineHeight * 0.35,
            )
            .firstOrNull;
        if (row == null) {
          rows.add([source]);
        } else {
          row.add(source);
        }
      }
      final rowLines = [
        for (final row in rows)
          OcrLine(
            '',
            1,
            bounds: row
                .map((line) => line.bounds)
                .reduce((a, b) => a.expandToInclude(b)),
            background: row.first.background,
            sourceLineHeight: row
                .map((line) => line.lineHeight)
                .reduce((a, b) => a > b ? a : b),
          ),
      ];
      final segments = _distributeTranslation(translations[i], rowLines);
      for (var j = 0; j < rows.length; j++) {
        final source = rows[j].length == 1 ? rows[j].single : rowLines[j];
        if (rows[j].length > 1) {
          for (final fragment in rows[j]) {
            final patch = fragment.backgroundPatch;
            placed.add(
              PositionedTranslation(
                '',
                (patch?.bounds ?? fragment.bounds.inflate(2)).intersect(screen),
                font,
                Color(fragment.background),
                backdrop: patch,
              ),
            );
          }
        }
        final patch = source.backgroundPatch;
        final box = (patch?.bounds ?? source.bounds.inflate(2)).intersect(
          screen,
        );
        if (box.isEmpty) continue;
        placed.add(
          PositionedTranslation(
            segments[j],
            box,
            (source.lineHeight * 0.75 * fontScale).clamp(10.0, 64.0),
            Color(source.background),
            backdrop: patch,
            paintBackground: rows[j].length == 1,
          ),
        );
      }
      continue;
    } else {
      final width = original.width.clamp(
        size.width < 80 ? size.width : 80.0,
        size.width,
      );
      final left = original.left.clamp(0.0, size.width - width);
      final top = original.bottom + 2 < belowMinimum
          ? belowMinimum
          : original.bottom + 2;
      final painter = TextPainter(
        text: TextSpan(
          text: translations[i],
          style: TextStyle(
            fontSize: font,
            height: 1.1,
            fontFamily: 'Microsoft YaHei',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: (width - 4).clamp(1, size.width));
      double bottom = (top + painter.height + 8).clamp(0.0, size.height);
      painter.dispose();
      for (final other in lines) {
        final box = other.bounds;
        if (box.top >= top && box.left < left + width && box.right > left) {
          bottom = bottom.clamp(top, box.top - 2 < top ? top : box.top - 2);
        }
      }
      if (bottom - top < 10) continue;
      area = Rect.fromLTRB(left, top, left + width, bottom).intersect(screen);
      final minimum = TextPainter(
        text: TextSpan(
          text: translations[i],
          style: const TextStyle(
            fontSize: 8,
            height: 1.1,
            fontFamily: 'Microsoft YaHei',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: (area.width - 4).clamp(1, size.width));
      final fits = minimum.height <= area.height - 4;
      minimum.dispose();
      if (!fits) continue;
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
  final backdrops = <ui.Image>[];
  try {
    for (final block in blocks) {
      if (!block.paintBackground) continue;
      canvas.save();
      canvas.clipRect(block.bounds);
      if (block.backdrop case final patch?) {
        final buffer = await ui.ImmutableBuffer.fromUint8List(patch.rgba);
        final descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: patch.bounds.width.round(),
          height: patch.bounds.height.round(),
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        try {
          final codec = await descriptor.instantiateCodec();
          try {
            final image = (await codec.getNextFrame()).image;
            backdrops.add(image);
            canvas.drawImageRect(
              image,
              Rect.fromLTWH(
                0,
                0,
                image.width.toDouble(),
                image.height.toDouble(),
              ),
              block.bounds,
              Paint(),
            );
          } finally {
            codec.dispose();
          }
        } finally {
          descriptor.dispose();
          buffer.dispose();
        }
      } else {
        canvas.drawRect(block.bounds, Paint()..color = block.background);
      }
      canvas.restore();
    }
    // All repairs precede text: overlapping OCR patches cannot erase a glyph
    // that was just rendered in an adjacent fragment.
    for (final block in blocks) {
      if (block.text.isEmpty) continue;
      canvas.save();
      canvas.clipRect(block.bounds);
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
  } finally {
    if (recorder.isRecording) recorder.endRecording().dispose();
    for (final image in backdrops) {
      image.dispose();
    }
  }
}
