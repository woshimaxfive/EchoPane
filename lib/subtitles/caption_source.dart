import 'package:flutter/foundation.dart';

/// Recognition output consumed by translation and subtitle presentation.
abstract class CaptionSource extends ChangeNotifier {
  bool get captionRunning;
  String? get captionError;
  List<String> get captionLines;
  String get captionSession;
  int? get captionDisplayId;
  String get waitingCaption;
}

enum RecognitionMode { screen, audio }

/// Selects the active source without coupling either recognizer to the other.
class CaptionRouter extends CaptionSource {
  CaptionRouter(this.screen, this.audio) {
    screen.addListener(_changed);
    audio.addListener(_changed);
  }
  final CaptionSource screen;
  final CaptionSource audio;
  RecognitionMode mode = RecognitionMode.screen;
  CaptionSource get active => mode == RecognitionMode.screen ? screen : audio;
  void select(RecognitionMode value) {
    if (mode == value) return;
    mode = value;
    notifyListeners();
  }

  void _changed() => notifyListeners();
  @override
  bool get captionRunning => active.captionRunning;
  @override
  String? get captionError => active.captionError;
  @override
  List<String> get captionLines => active.captionLines;
  @override
  String get captionSession => '${mode.name}:${active.captionSession}';
  @override
  int? get captionDisplayId => screen.captionDisplayId;
  @override
  String get waitingCaption => active.waitingCaption;
  @override
  void dispose() {
    screen.removeListener(_changed);
    audio.removeListener(_changed);
    super.dispose();
  }
}
