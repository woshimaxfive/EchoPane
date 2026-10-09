import 'dart:typed_data';

/// A revisable speech turn; only a final pair belongs in transcript history.
class SpeechUpdate {
  const SpeechUpdate({
    required this.id,
    required this.source,
    required this.translation,
    this.language = '',
    this.isFinal = false,
  });
  final String id, source, translation, language;
  final bool isFinal;
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
