import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../subtitles/caption_source.dart';
import '../translation/translation_controller.dart';

/// A received caption, not a media timestamp or a persistent transcript.
class CaptionEntry {
  CaptionEntry({
    required this.id,
    required this.receivedAt,
    required this.origin,
    required List<String> originals,
    List<String> translations = const [],
    this.target,
  }) : originals = List.unmodifiable(originals),
       translations = List.unmodifiable(translations);

  final int id;
  final DateTime receivedAt;
  final RecognitionMode origin;
  final List<String> originals;
  final List<String> translations;
  final String? target;
  int get characters =>
      originals.fold(0, (n, s) => n + s.length) +
      translations.fold(0, (n, s) => n + s.length);

  CaptionEntry translated(List<String> lines, String language) => CaptionEntry(
    id: id,
    receivedAt: receivedAt,
    origin: origin,
    originals: originals,
    translations: lines,
    target: language,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'origin': origin.name,
    'originals': originals,
    'translations': translations,
    'target': target,
  };
}

/// Bounded, in-memory history for this app lifetime. Only explicit export writes it.
class CaptionHistory extends ChangeNotifier {
  CaptionHistory(
    this.source,
    this.translation, {
    RecognitionMode Function()? origin,
    DateTime Function()? now,
    this.maxEntries = 1000,
    this.maxCharacters = 1000000,
  }) : _origin = origin ?? (() => RecognitionMode.screen),
       _now = now ?? DateTime.now {
    assert(identical(source, translation.source));
    assert(maxEntries > 0 && maxCharacters > 0);
    source.addListener(_changed);
    translation.addListener(_changed);
    _changed();
  }

  final CaptionSource source;
  final TranslationController translation;
  final RecognitionMode Function() _origin;
  final DateTime Function() _now;
  final int maxEntries, maxCharacters;
  final _entries = <CaptionEntry>[];
  int dropped = 0;
  int _characters = 0, _nextId = 0;
  int? _activeId;
  String? _signature;
  final _confirmedSeen = <String>{};
  List<CaptionEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  int get characters => _characters;

  String _fingerprint(List<String> lines) => jsonEncode(
    lines.map((s) => s.trim().replaceAll(RegExp(r'\s+'), ' ')).toList(),
  );

  void _changed() {
    final confirmed = source.captionConfirmed;
    if (confirmed != null) {
      var changed = false;
      for (final caption in confirmed) {
        final signature = '${source.captionSession}:${caption.id}';
        if (!_confirmedSeen.add(signature)) continue;
        final entry = CaptionEntry(
          id: ++_nextId,
          receivedAt: _now(),
          origin: _origin(),
          originals: [caption.original],
          translations: [caption.translation],
          target: caption.target,
        );
        _entries.add(entry);
        _characters += entry.characters;
        changed = true;
      }
      while (_confirmedSeen.length > maxEntries + 256) {
        _confirmedSeen.remove(_confirmedSeen.first);
      }
      _trim();
      if (changed) notifyListeners();
      _signature = null;
      _activeId = null;
      return;
    }
    final lines = source.captionLines;
    if (!source.captionRunning ||
        source.captionError != null ||
        lines.isEmpty ||
        lines.every((s) => s.trim().isEmpty)) {
      _signature = null;
      _activeId = null;
      return;
    }
    final signature = jsonEncode([
      source.captionSession,
      source.captionRevision,
      _fingerprint(lines),
    ]);
    var changed = false;
    if (_signature != signature) {
      _signature = signature;
      final entry = CaptionEntry(
        id: ++_nextId,
        receivedAt: _now(),
        origin: _origin(),
        originals: lines,
      );
      _activeId = entry.id;
      _entries.add(entry);
      _characters += entry.characters;
      changed = true;
    }
    final index = _entries.indexWhere((e) => e.id == _activeId);
    if (index >= 0 &&
        translation.phase == TranslationPhase.ready &&
        translation.translations.length == lines.length &&
        _fingerprint(translation.originals) == _fingerprint(lines)) {
      final old = _entries[index];
      if (!listEquals(old.translations, translation.translations) ||
          old.target != translation.settings.target) {
        final next = old.translated(
          translation.translations,
          translation.settings.target,
        );
        _entries[index] = next;
        _characters += next.characters - old.characters;
        changed = true;
      }
    }
    changed = _trim() || changed;
    if (changed) notifyListeners();
  }

  bool _trim() {
    var changed = false;
    while (_entries.length > maxEntries || _characters > maxCharacters) {
      final removed = _entries.removeAt(0);
      _characters -= removed.characters;
      if (removed.id == _activeId) _activeId = null;
      dropped++;
      changed = true;
    }
    return changed;
  }

  void clear() {
    _entries.clear();
    _activeId = null;
    _characters = dropped = 0;
    // Keep the current signature suppressed until the recognizer changes it.
    notifyListeners();
  }

  CaptionSnapshot snapshot() => CaptionSnapshot(entries, _now(), dropped);

  @override
  void dispose() {
    source.removeListener(_changed);
    translation.removeListener(_changed);
    _entries.clear();
    super.dispose();
  }
}

class CaptionSnapshot {
  CaptionSnapshot(List<CaptionEntry> entries, this.exportedAt, this.dropped)
    : entries = List.unmodifiable(entries);
  final List<CaptionEntry> entries;
  final DateTime exportedAt;
  final int dropped;

  String toText() {
    final out = StringBuffer('EchoPane · 随幕 · 字幕记录\n');
    out.writeln('导出时间（UTC）：${exportedAt.toUtc().toIso8601String()}');
    out.writeln('时间为字幕收到时间，不是视频时间轴。');
    if (dropped > 0) out.writeln('容量限制已移除 $dropped 条较早记录。');
    for (final e in entries) {
      out.writeln();
      out.writeln(
        '[${e.receivedAt.toUtc().toIso8601String()}] ${e.origin == RecognitionMode.audio ? '音频' : '屏幕'}',
      );
      for (var i = 0; i < e.originals.length; i++) {
        out.writeln(e.originals[i]);
        if (i < e.translations.length) out.writeln(e.translations[i]);
      }
    }
    return out.toString();
  }

  String toJson() =>
      '${const JsonEncoder.withIndent('  ').convert({'version': 1, 'exportedAt': exportedAt.toUtc().toIso8601String(), 'timeBasis': 'caption_received', 'droppedEntries': dropped, 'entries': entries.map((e) => e.toJson()).toList()})}\n';
}
