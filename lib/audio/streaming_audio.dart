import 'dart:typed_data';

/// A revisable speech turn; only a final pair belongs in transcript history.
class SpeechUpdate {
  const SpeechUpdate({
    required this.id,
    required this.source,
    required this.translation,
    this.language = '',
    this.isFinal = false,
    this.sequence,
  });
  final String id, source, translation, language;
  final bool isFinal;

  /// Source-turn order, independent of when translated text arrives.
  final int? sequence;
}

abstract interface class AudioStreamDiagnostics {
  List<Map<String, Object?>> get diagnostics;
}

/// A skipped turn; capture and subsequent turns may continue.
class AudioStreamNotice implements Exception {
  const AudioStreamNotice(this.message);
  final String message;
}

abstract interface class AudioStreamSession {
  Stream<SpeechUpdate> get updates;
  Future<void> get ready;
  void addPcm(Uint8List pcm);
  Future<void> finish();
  Future<void> cancel();
}

class AudioStreamFailure implements Exception {
  const AudioStreamFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
