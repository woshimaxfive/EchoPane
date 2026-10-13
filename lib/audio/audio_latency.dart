import 'streaming_audio.dart';

/// Monotonic application timings, independent of provider clocks and text.
/// Frame times mean successful submission, not physical monitor presentation.
class AudioLatencyTracker {
  AudioLatencyTracker({Duration Function()? now}) {
    final clock = Stopwatch()..start();
    _now = now ?? (() => clock.elapsed);
    reset();
  }
  late final Duration Function() _now;
  Duration _origin = Duration.zero;
  final _turns = <String, _Timing>{};
  int _alias = 0, _pcmBytes = 0;
  int? _firstPcmMs;
  int get _ms => (_now() - _origin).inMilliseconds;

  void reset() {
    _origin = _now();
    _turns.clear();
    _alias = _pcmBytes = 0;
    _firstPcmMs = null;
  }

  void pcm(int bytes) {
    if (bytes <= 0) return;
    _firstPcmMs ??= _ms;
    _pcmBytes += bytes;
  }

  void receive(SpeechUpdate update) {
    if (update.source.trim().isEmpty && update.translation.trim().isEmpty) {
      return;
    }
    final turn = _turns.putIfAbsent(
      update.id,
      () => _Timing(++_alias, update.sequence),
    );
    if (update.source.trim().isNotEmpty) turn.sourceMs ??= _ms;
    if (update.translation.trim().isNotEmpty) turn.translationMs ??= _ms;
    if (update.isFinal) turn.finalMs ??= _ms;
    while (_turns.length > 32) {
      _turns.remove(_turns.keys.first);
    }
  }

  void presented(String id, {required bool translated}) {
    final turn = _turns[id];
    if (turn == null) return;
    if (translated && turn.translationMs != null) {
      turn.translationFrameMs ??= _ms;
    } else if (!translated && turn.sourceMs != null) {
      turn.sourceFrameMs ??= _ms;
    }
  }

  List<Map<String, Object?>> get diagnostics => [
    if (_firstPcmMs != null || _turns.isNotEmpty)
      {
        'event': 'audio.application_timing',
        'clock': 'application_session',
        'firstPcmQueuedMs': _firstPcmMs,
        'pcmQueuedMs': _pcmBytes ~/ 32, // 16 kHz mono PCM16.
        'frameMeaning': 'submitted',
      },
    for (final turn in _turns.values)
      {
        'event': 'turn.application_timing',
        'clock': 'application_session',
        'turn': turn.alias,
        if (turn.sequence != null) 'sourceTurn': turn.sequence,
        'sourceReceivedMs': turn.sourceMs,
        'translationReceivedMs': turn.translationMs,
        'finalReceivedMs': turn.finalMs,
        'sourceFrameMs': turn.sourceFrameMs,
        'translationFrameMs': turn.translationFrameMs,
        'sourceToFrameMs': turn.sourceMs == null || turn.sourceFrameMs == null
            ? null
            : turn.sourceFrameMs! - turn.sourceMs!,
        'translationToFrameMs':
            turn.translationMs == null || turn.translationFrameMs == null
            ? null
            : turn.translationFrameMs! - turn.translationMs!,
      },
  ];
}

class _Timing {
  _Timing(this.alias, this.sequence);
  final int alias;
  final int? sequence;
  int? sourceMs, translationMs, finalMs, sourceFrameMs, translationFrameMs;
}
