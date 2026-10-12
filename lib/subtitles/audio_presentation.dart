import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'caption_source.dart';
import 'overlay_renderer.dart';
import 'overlay_settings.dart';

// Only presentation is buffered. Recognition and confirmed history keep the
// complete provider turns, with no inferred alignment between language lines.
class AudioSubtitlePresentation {
  final _turns = <_Turn>[];
  final _seen = <String>{};
  bool _started = false;

  void reset() {
    _turns.clear();
    _seen.clear();
    _started = false;
  }

  void update(List<CaptionTurn> turns, Duration now) {
    // Opening the window should show current speech, not replay old turns.
    if (!_started && turns.isNotEmpty) {
      _seen.addAll(turns.take(turns.length - 1).map((t) => t.id));
      _started = true;
    }
    for (final turn in turns) {
      final known = _turns.where((t) => t.id == turn.id).firstOrNull;
      if (known != null) {
        known.update(turn, now);
      } else if (!_seen.contains(turn.id) &&
          (turn.original.isNotEmpty || turn.translation.isNotEmpty)) {
        _seen.add(turn.id);
        _turns.add(_Turn(turn, now));
      }
    }
    // Excess speech must not create an unbounded playback delay.
    while (_turns.length > 4) {
      _turns.removeAt(0);
    }
    while (_seen.length > 64) {
      _seen.remove(_seen.first);
    }
  }

  List<SubtitleRow> layout({
    required double width,
    required double height,
    required OverlaySettings settings,
    required bool locked,
    required Duration now,
  }) {
    final available = height - (locked ? 12 : 42) - 12;
    final lineHeight = settings.fontSize * 1.35;
    final capacity = math.min(
      settings.maxLines,
      (available / (lineHeight + 4)).floor(),
    );
    if (_turns.isEmpty || width <= 40 || capacity < 1) return [];
    final bilingual = settings.mode == SubtitleMode.bilingual;
    final pairSize = bilingual ? 2 : 1;
    final slots = capacity >= pairSize * 2 ? math.min(2, _turns.length) : 1;
    final rowsPerTurn = capacity ~/ slots;
    List<SubtitleRow> draw(_Turn turn) => turn.layout(
      width - 40,
      rowsPerTurn,
      settings,
      now,
      catchUp:
          _turns.length > 1 &&
          turn == _turns.first &&
          turn.isFinal &&
          turn.shownAt != null &&
          now - turn.shownAt! > const Duration(seconds: 6),
    );
    var rows = [for (final turn in _turns.take(slots)) ...draw(turn)];
    final first = _turns.first;
    if (_turns.length > 1 &&
        (first.read(now) ||
            (!first.isFinal &&
                now - first.shownAt! > const Duration(seconds: 10)))) {
      _turns.removeAt(0);
      rows = [for (final turn in _turns.take(slots)) ...draw(turn)];
    }
    return rows;
  }
}

class _Turn {
  _Turn(CaptionTurn turn, Duration now) : id = turn.id {
    update(turn, now);
  }
  final String id;
  final original = _Lane(), translation = _Lane();
  bool isFinal = false;
  Duration? shownAt;

  void update(CaptionTurn turn, Duration now) {
    final completed =
        turn.isFinal &&
        (!isFinal || (translation.text.isEmpty && turn.translation.isNotEmpty));
    original.update(turn.original);
    translation.update(turn.translation);
    if (completed) {
      // Count reading opportunity from final availability, including late finals.
      original.protect(now);
      translation.protect(now);
    }
    isFinal = turn.isFinal;
  }

  List<SubtitleRow> layout(
    double width,
    int capacity,
    OverlaySettings settings,
    Duration now, {
    bool catchUp = false,
  }) {
    shownAt ??= now;
    if (settings.mode == SubtitleMode.original) {
      translation.visible = false;
      return original.layout(
        width,
        capacity,
        settings,
        false,
        now,
        tail: catchUp,
      );
    }
    if (settings.mode == SubtitleMode.translated) {
      original.visible = false;
      return translation.layout(
        width,
        capacity,
        settings,
        false,
        now,
        tail: catchUp,
      );
    }
    if (translation.text.isEmpty) {
      translation.visible = false;
      return original.layout(
        width,
        capacity,
        settings,
        false,
        now,
        tail: catchUp,
      );
    }
    if (capacity == 1) {
      original.visible = false;
      return translation.layout(width, 1, settings, false, now, tail: catchUp);
    }
    return [
      ...original.layout(width, 1, settings, true, now, tail: catchUp),
      ...translation.layout(
        width,
        capacity - 1,
        settings,
        false,
        now,
        tail: catchUp,
      ),
    ];
  }

  bool read(Duration now) =>
      isFinal &&
      (translation.visible ? translation.read(now) : original.read(now));
}

class _Line {
  const _Line(this.start, this.end, this.text);
  final int start, end;
  final String text;
}

class _Lane {
  String text = '', _displayed = '';
  int _anchor = 0;
  List<_Line> _lines = [];
  String _layoutKey = '';
  Duration _until = Duration.zero;
  bool visible = false, _atEnd = false;

  void update(String value) {
    // Bound presentation memory; complete final text remains in history.
    if (value.length > 8192) {
      var start = value.length - 8192;
      if (value.codeUnitAt(start) >= 0xdc00 &&
          value.codeUnitAt(start) <= 0xdfff) {
        start++;
      }
      value = value.substring(start);
    }
    if (value == text) return;
    var common = 0;
    while (common < text.length &&
        common < value.length &&
        text.codeUnitAt(common) == value.codeUnitAt(common)) {
      common++;
    }
    // A correction before the viewport is reread, not appended as a new turn.
    _anchor = math.min(_anchor, common);
    text = value;
    _layoutKey = '';
  }

  void protect(Duration now) {
    _until = _max(_until, now + const Duration(milliseconds: 1200));
  }

  List<SubtitleRow> layout(
    double width,
    int capacity,
    OverlaySettings settings,
    bool secondary,
    Duration now, {
    bool tail = false,
  }) {
    visible = text.isNotEmpty;
    if (!visible) return [];
    final key = '$width:${settings.fontSize}:$secondary';
    if (_layoutKey != key) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: subtitleTextStyle(settings, secondary),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      _lines = [
        for (final line in painter.computeLineMetrics()) _line(painter, line),
      ];
      painter.dispose();
      _layoutKey = key;
    }
    if (_lines.isEmpty) return [];
    var index = _lines.indexWhere((line) => line.end > _anchor);
    if (index < 0) index = _lines.length - 1;
    // Keep at most eight pending lines even in a long, uninterrupted turn.
    index = math.max(index, _lines.length - capacity - 8);
    if (tail) index = math.max(index, _lines.length - capacity);
    var selected = _lines.skip(index).take(capacity).toList();
    var display = selected.map((line) => line.text).join('\n');
    if (display != _displayed) {
      var common = 0;
      while (common < display.length &&
          common < _displayed.length &&
          display.codeUnitAt(common) == _displayed.codeUnitAt(common)) {
        common++;
      }
      _until = _max(_until, now) + _readingTime(display.substring(common));
      _until = _min(_until, now + const Duration(seconds: 4));
    } else if (now >= _until && index + capacity < _lines.length) {
      index++;
      selected = _lines.skip(index).take(capacity).toList();
      display = selected.map((line) => line.text).join('\n');
      _until = now + _readingTime(selected.last.text);
    }
    _anchor = _lines[index].start;
    _displayed = display;
    _atEnd = index + capacity >= _lines.length;
    return selected
        .map((line) => SubtitleRow(line.text, secondary: secondary))
        .toList();
  }

  _Line _line(TextPainter painter, ui.LineMetrics line) {
    final position = painter.getPositionForOffset(
      Offset(0, line.baseline - line.ascent / 2),
    );
    final range = painter.getLineBoundary(position);
    return _Line(
      range.start,
      range.end,
      text.substring(range.start, range.end).trimRight(),
    );
  }

  bool read(Duration now) => _atEnd && now >= _until;
}

Duration _readingTime(String text) {
  double seconds = 0;
  for (final rune in text.runes) {
    seconds += rune >= 0x2e80 && rune <= 0x9fff ? 1 / 9 : 1 / 18;
  }
  return Duration(milliseconds: (seconds * 1000).round().clamp(750, 4000));
}

Duration _max(Duration a, Duration b) => a > b ? a : b;
Duration _min(Duration a, Duration b) => a < b ? a : b;
