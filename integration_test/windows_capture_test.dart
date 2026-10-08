import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:echopane/main.dart' as app;
import 'package:echopane/capture/capture_platform.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures physical pixels while excluding its own window', (
    tester,
  ) async {
    await app.main();
    await tester.pumpAndSettle();
    const channel = WindowsCapturePlatform.channel;
    final fixture = await channel.invokeMapMethod<Object?, Object?>(
      'debugCreateFixture',
    );
    expect(fixture, isNotNull);
    await tester.pumpAndSettle();
    final edge = await channel.invokeListMethod<int>('debugSampleWindowEdge');
    expect(edge![0], closeTo(32, 4));
    expect(edge[1], closeTo(176, 4));
    expect(edge[2], closeTo(112, 4));
    final selected = await channel.invokeMapMethod<Object?, Object?>(
      'debugSelectRegion',
      {'cancel': false},
    );
    expect(selected, {'x': 100, 'y': 80, 'width': 260, 'height': 160});
    expect(
      await channel.invokeMethod<Object?>('debugSelectRegion', {
        'cancel': true,
      }),
      isNull,
    );
    final displays = await WindowsCapturePlatform().displays();
    final region = CaptureRegion.fromMap(fixture!);
    try {
      await channel.invokeMethod<int>('start', {
        'displayId': displays.first.id,
        'region': region.toMap(),
      });
      Map<Object?, Object?>? snapshot;
      for (int attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
        snapshot = await channel.invokeMapMethod<Object?, Object?>('snapshot');
        if ((snapshot!['frames']! as int) >= 3) break;
      }
      expect(snapshot!['error'], isNull);
      expect(snapshot['frames'], greaterThanOrEqualTo(3));
      expect(snapshot['width'], 420);
      expect(snapshot['height'], 240);
      expect(snapshot['excluded'], isTrue);
      expect(snapshot['topmost'], isTrue);
      final evidence = Map<Object?, Object?>.from(snapshot);
      evidence['transparentEdge'] = edge;
      final pixel = snapshot['centerPixel']! as List<Object?>;
      expect(pixel[0], closeTo(32, 3));
      expect(pixel[1], closeTo(176, 3));
      expect(pixel[2], closeTo(112, 3));
      await channel.invokeMethod<void>('stop');
      await tester.pump(const Duration(milliseconds: 300));
      snapshot = await channel.invokeMapMethod<Object?, Object?>('snapshot');
      expect(snapshot!['frames'], 0);
      await expectLater(
        channel.invokeMethod<int>('start', {
          'displayId': displays.first.id,
          'region': {'x': -1, 'y': 0, 'width': 420, 'height': 240},
        }),
        throwsA(isA<PlatformException>()),
      );
      await expectLater(
        channel.invokeMethod<int>('start', {'displayId': -1}),
        throwsA(isA<PlatformException>()),
      );
      snapshot = await channel.invokeMapMethod<Object?, Object?>('snapshot');
      expect(snapshot!['frames'], 0);
      await windowManager.setAlwaysOnTop(false);
      snapshot = await channel.invokeMapMethod<Object?, Object?>('snapshot');
      expect(snapshot!['topmost'], isFalse);

      await tester.tap(find.byKey(const Key('capture-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('停止'), findsOneWidget);
      await windowManager.minimize();
      await tester.pump(const Duration(milliseconds: 500));
      expect(await windowManager.isVisible(), isFalse);
      snapshot = await channel.invokeMapMethod<Object?, Object?>('snapshot');
      expect(snapshot!['frames'], greaterThan(0));
      await windowManager.restore();
      await windowManager.show();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('开始'), findsOneWidget);
      const artifactDirectory = String.fromEnvironment('ECHO_TEST_ARTIFACTS');
      if (artifactDirectory.isNotEmpty) {
        final directory = Directory(artifactDirectory)
          ..createSync(recursive: true);
        await File('${directory.path}/capture-result.json').writeAsString(
          jsonEncode(
            evidence.map((key, value) => MapEntry(key.toString(), value)),
          ),
          encoding: utf8,
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('window-content')),
        );
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${directory.path}/window.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }
    } finally {
      await channel.invokeMethod<void>('stop');
      await channel.invokeMethod<void>('debugDestroyFixture');
    }
  });
}
