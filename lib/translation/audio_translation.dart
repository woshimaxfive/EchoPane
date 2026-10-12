import 'dart:async';

import 'package:flutter/foundation.dart';

import '../subtitles/caption_source.dart';
import 'provider.dart';
import 'settings.dart';

class AudioTurnTranslation {
  const AudioTurnTranslation(this.source, this.text, this.isFinal);
  final String source, text;
  final bool isFinal;
}

/// One request at a time; new ASR hypotheses never cancel a request in flight.
/// Pending revisions coalesce by turn ID, so playback cannot grow the queue.
class AudioTranslationQueue extends ChangeNotifier {
  AudioTranslationQueue(
    this.provider, {
    this.quiet = const Duration(milliseconds: 650),
  });
  final TranslationProvider provider;
  final Duration quiet;
  final _turns = <String, CaptionTurn>{};
  final _pending = <String, CaptionTurn>{};
  final _scheduled = <String, String>{};
  final _output = <String, AudioTurnTranslation>{};
  final _timers = <String, Timer>{};
  TranslationRequest? _active;
  TranslationSettings _settings = const TranslationSettings();
  String _key = '';
  int _generation = 0;
  bool _disposed = false;
  String? error;
  bool get busy => _active != null || _pending.isNotEmpty;
  AudioTurnTranslation? result(String id) => _output[id];

  void update(
    List<CaptionTurn> turns,
    TranslationSettings settings,
    String key,
  ) {
    _settings = settings;
    _key = key;
    for (final turn in turns) {
      final previous = _turns[turn.id];
      if (previous?.original == turn.original &&
          previous?.isFinal == turn.isFinal) {
        continue;
      }
      _turns[turn.id] = turn;
      _timers.remove(turn.id)?.cancel();
      if (turn.isFinal) {
        _enqueue(turn);
        continue;
      }
      final words = turn.original.trim().split(RegExp(r'\s+'));
      final oldWords = previous?.original.trim().split(RegExp(r'\s+')) ?? [];
      var common = 0;
      while (common < words.length - 1 &&
          common < oldWords.length &&
          words[common] == oldWords[common]) {
        common++;
      }
      final prefix = words.take(common).join(' ');
      final scheduledWords = (_scheduled[turn.id] ?? '')
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length;
      if (common >= 4 && common >= scheduledWords + 4) {
        _enqueue(CaptionTurn(turn.id, prefix, '', false));
      }
      _timers[turn.id] = Timer(quiet, () {
        _timers.remove(turn.id);
        if (_disposed) return;
        // A trailing partial token may not be a complete word yet.
        final prefix = words.take(words.length - 1).join(' ');
        if (words.length >= 5) {
          _enqueue(CaptionTurn(turn.id, prefix, '', false));
        }
      });
    }
    // Retain completed translations long enough for final-only history updates.
    while (_turns.length > 64) {
      final id = _turns.keys.first;
      _turns.remove(id);
      _pending.remove(id);
      _scheduled.remove(id);
      _output.remove(id);
      _timers.remove(id)?.cancel();
    }
  }

  void _enqueue(CaptionTurn turn) {
    if (_disposed || turn.original.trim().isEmpty) return;
    final output = _output[turn.id];
    if (_scheduled[turn.id] == turn.original &&
        (!turn.isFinal || output?.isFinal == true)) {
      return;
    }
    _scheduled[turn.id] = turn.original;
    _pending[turn.id] = turn;
    while (_pending.length > 16) {
      _pending.remove(_pending.keys.first);
      error = '翻译跟不上播放速度，部分片段仅保留原文';
    }
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_disposed || _active != null || _pending.isEmpty) return;
    final id = _pending.keys.first;
    final turn = _pending.remove(id)!;
    final token = _generation;
    TranslationRequest? request;
    try {
      request = provider.translate(_settings, _key, [turn.original]);
      _active = request;
      notifyListeners();
      final text = await request.result;
      if (_disposed || token != _generation) return;
      if (text.length != 1 || text.single.trim().isEmpty) {
        throw const TranslationFailure('译文段落不完整，请重试');
      }
      _output[id] = AudioTurnTranslation(
        turn.original,
        text.single,
        turn.isFinal,
      );
      error = null;
    } catch (failure) {
      if (!_disposed && token == _generation) {
        error = failure is TranslationFailure
            ? failure.message
            : '翻译失败，原文识别继续；可重试翻译';
      }
    } finally {
      if (identical(_active, request)) _active = null;
      if (!_disposed && token == _generation) {
        notifyListeners();
        unawaited(_drain());
      }
    }
  }

  void retry() {
    error = null;
    _scheduled.clear();
    for (final turn in _turns.values) {
      if (turn.isFinal) {
        if (_output[turn.id]?.isFinal != true) _enqueue(turn);
      } else {
        final words = turn.original.trim().split(RegExp(r'\s+'));
        if (words.length >= 5) {
          _enqueue(
            CaptionTurn(
              turn.id,
              words.take(words.length - 1).join(' '),
              '',
              false,
            ),
          );
        }
      }
    }
  }

  void reset() {
    _generation++;
    _active?.cancel();
    _active = null;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _turns.clear();
    _pending.clear();
    _scheduled.clear();
    _output.clear();
    _key = '';
    error = null;
  }

  @override
  void dispose() {
    _disposed = true;
    reset();
    super.dispose();
  }
}
