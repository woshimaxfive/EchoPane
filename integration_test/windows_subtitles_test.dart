import 'dart:io';

import 'package:echopane/main.dart' as app;
import 'package:echopane/audio/audio_controller.dart';
import 'package:echopane/audio/streaming_audio.dart';
import 'package:echopane/subtitles/overlay_platform.dart';
import 'package:echopane/subtitles/overlay_settings.dart';
import 'package:echopane/screen_translation/screen_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import '../test/streaming_audio_test.dart' show StreamPlatform, StreamSession;
import '../test/translation_test.dart' show MemorySettings, MemoryCredentials;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'subtitle window is audio-only across mode changes and tray actions',
    (tester) async {
      final folder = await Directory.systemTemp.createTemp(
        'echopane-audio-subtitles-',
      );
      final session = StreamSession();
      await app.startApplication(
        audioPlatform: StreamPlatform(),
        audioStreamFactory: () async => session,
        settingsStore: MemorySettings(),
        credentials: MemoryCredentials()..key = 'fixture',
        overlaySettingsStore: FileOverlaySettingsStore(
          path: '${folder.path}/subtitles.json',
        ),
        screenOverlaySettingsStore: FileScreenOverlaySettingsStore(
          path: '${folder.path}/screen.json',
        ),
      );
      await tester.pumpAndSettle();
      final window = tester.widget<app.CaptureWindow>(
        find.byType(app.CaptureWindow),
      );
      final overlay = window.overlay!;
      final audio = window.audio!;
      const native = WindowsOverlayPlatform.channel;
      Future<Map<Object?, Object?>> state() async =>
          await native.invokeMapMethod<Object?, Object?>('state') ?? {};
      Future<void> mode(String label) async {
        await tester.tap(find.byKey(const Key('recognition-mode')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 80 && !done(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await audio.poll();
        }
        expect(done(), true);
      }

      try {
        expect(find.text('原位翻译'), findsOneWidget);
        expect(find.byKey(const Key('overlay-settings')), findsNothing);
        expect(find.byKey(const Key('ocr-text')), findsNothing);
        await overlay.show(true, restore: true);
        expect(overlay.window.visible, false);
        expect((await state())['visible'], false);
        await mode('音频翻译');
        expect(find.byKey(const Key('overlay-settings')), findsOneWidget);
        await audio.selectBackend(AudioBackend.cloud);
        window.translation!.setEnabled(true);
        await audio.start();
        await until(() => audio.running);
        session.controller.add(
          const SpeechUpdate(
            id: 'one',
            source: 'Audio only',
            translation: '只显示音频',
            isFinal: true,
          ),
        );
        await until(() => audio.text.isNotEmpty);
        await tester.tap(find.byKey(const Key('overlay-settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('overlay-visible')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('overlay-save')));
        await tester.pumpAndSettle();
        await until(
          () => overlay.displayRows.any((row) => row.text == '只显示音频'),
        );
        final opened = await state();
        expect(opened['visible'], true);
        expect(opened['excluded'], true);
        expect(opened['topmost'], true);
        await overlay.show(true, locked: true);
        expect(await native.invokeMethod<int>('debugHitTest'), -1);
        await native.invokeMethod<Object?>('debugHotkey');
        await tester.pump(const Duration(milliseconds: 200));
        expect(overlay.window.locked, false);
        await overlay.save(overlay.settings.copyWith(allowCapture: true));
        expect((await state())['excluded'], false);
        await windowManager.minimize();
        await tester.pump(const Duration(milliseconds: 300));
        expect(await windowManager.isVisible(), false);
        expect(overlay.window.visible, true);
        await windowManager.restore();
        await windowManager.show();
        await windowManager.setSize(const Size(680, 520));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await mode('原位翻译');
        expect(audio.running, false);
        expect(overlay.window.visible, false);
        expect(overlay.displayRows, isEmpty);
        expect(find.byKey(const Key('overlay-settings')), findsNothing);
        // The tray invokes this same method; it cannot reopen a screen subtitle window.
        await overlay.show(true, restore: true);
        expect((await state())['visible'], false);
        await mode('音频翻译');
        await overlay.show(true, restore: true);
        expect(overlay.window.visible, true);
        expect(overlay.displayRows, isEmpty);
        await overlay.close();
        debugPrint('AUDIO_ONLY_SUBTITLES_OK');
      } finally {
        await audio.stop();
        await overlay.close();
        await window.screenOverlay!.close();
        await session.controller.close();
        await windowManager.setSize(const Size(900, 720));
        await windowManager.show();
        final prefix =
            '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}echopane-audio-subtitles-';
        if (folder.absolute.path.startsWith(prefix)) {
          await folder.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
