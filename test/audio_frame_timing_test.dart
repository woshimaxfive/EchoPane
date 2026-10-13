import 'dart:async';
import 'dart:typed_data';

import 'package:echopane/subtitles/caption_source.dart';
import 'package:echopane/subtitles/overlay_controller.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/translation/translation_controller.dart';
import 'package:echopane/translation/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'translation_test.dart'
    show FakeTranslations, MemorySettings, MemoryCredentials;

class _Source extends CaptionSource {
  String id = 'first';
  int session = 1;
  final submitted = <(String, bool)>[];
  @override
  bool get captionRunning => true;
  @override
  String? get captionError => null;
  @override
  List<String> get captionLines => ['Hello'];
  @override
  List<String> get captionTranslations => ['你好'];
  @override
  List<CaptionTurn> get captionTurns => [CaptionTurn(id, 'Hello', '你好', true)];
  @override
  String get captionSession => '$session';
  @override
  int? get captionDisplayId => null;
  @override
  String get waitingCaption => '';
  @override
  bool get supportsAudioSubtitles => true;
  @override
  void captionPresented(String id, {required bool translated}) =>
      submitted.add((id, translated));
  void change(String next) {
    id = next;
    notifyListeners();
  }
}

class _Platform implements OverlayPlatform {
  int frames = 0;
  bool succeeds = false;
  Completer<bool>? pending;
  @override
  void listen(void Function(OverlayWindowState)? listener) {}
  @override
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool locked,
    bool restore = false,
    bool allowCapture = false,
    int? displayId,
  }) async => OverlayWindowState(
    visible: visible,
    locked: locked,
    width: 720,
    height: 220,
  );
  @override
  Future<bool> present(int width, int height, Uint8List rgba) async {
    frames++;
    return pending?.future ?? succeeds;
  }
}

class _Styles implements OverlaySettingsStore {
  @override
  Future<OverlaySettings> read() async => const OverlaySettings();
  @override
  Future<void> write(OverlaySettings settings) async {}
}

void main() {
  testWidgets(
    'only successful current-session frames report readable lane timing',
    (tester) async {
      await tester.runAsync(() async {
        final screen = _Source(), audio = _Source();
        final router = CaptionRouter(screen, audio)
          ..select(RecognitionMode.audio);
        final translation = TranslationController(
          router,
          FakeTranslations(),
          MemorySettings()
            ..value = const TranslationSettings(
              baseUrl: 'http://127.0.0.1',
              model: 'fixture',
            ),
          MemoryCredentials(),
        );
        final platform = _Platform();
        final overlay = OverlayController(
          router,
          translation,
          platform,
          _Styles(),
        );
        Future<void> waitFor(bool Function() predicate) async {
          for (int i = 0; i < 100; i++) {
            if (predicate()) return;
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('Frame timing did not settle');
        }

        try {
          await translation.initialize();
          translation.setEnabled(true);
          await overlay.initialize();
          await overlay.show(true, locked: true);
          await waitFor(() => platform.frames > 0);
          expect(
            audio.submitted,
            isEmpty,
            reason: 'A failed submission is not a displayed subtitle',
          );
          platform.pending = Completer<bool>();
          final before = platform.frames;
          await overlay.save(overlay.settings.copyWith(fontSize: 26));
          await waitFor(() => platform.frames > before);
          await overlay.close();
          audio.session++;
          audio.change('second');
          platform.pending!.complete(true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            audio.submitted,
            isEmpty,
            reason: 'Dismissed or previous-session frames must not count',
          );
          platform.pending = null;
          platform.succeeds = true;
          await overlay.show(true, locked: true);
          await waitFor(() => audio.submitted.contains(('second', true)));
          expect(audio.submitted, contains(('second', false)));
          expect(
            screen.submitted,
            isEmpty,
            reason: 'Audio timing follows only the active source',
          );
          audio.change('third');
          await waitFor(() => audio.submitted.contains(('third', true)));
        } finally {
          if (platform.pending?.isCompleted == false) {
            platform.pending!.complete(false);
          }
          overlay.dispose();
          translation.dispose();
          router.dispose();
          screen.dispose();
          audio.dispose();
        }
      });
    },
  );
}
