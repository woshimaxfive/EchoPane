import 'dart:async';

import 'package:echopane/capture/capture_controller.dart';
import 'package:echopane/capture/capture_platform.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePlatform implements CapturePlatform {
  Completer<int>? starting;
  Completer<CaptureSnapshot>? reading;
  int stops = 0;
  CaptureRegion? selection;

  @override
  Future<List<CaptureDisplay>> displays() async => [
    const CaptureDisplay(
      id: 0,
      name: 'Display',
      width: 1920,
      height: 1080,
      primary: true,
    ),
  ];
  @override
  Future<CaptureRegion?> selectRegion(int displayId) async => selection;
  @override
  Future<int> start(int displayId, CaptureRegion? region) async =>
      starting == null ? 7 : starting!.future;
  @override
  Future<void> stop() async => stops++;
  @override
  Future<CaptureSnapshot> snapshot() async => reading == null
      ? const CaptureSnapshot(frames: 1, width: 320, height: 180)
      : reading!.future;
}

void main() {
  test(
    'stopping drains a pending start and does not resurrect its texture',
    () async {
      final platform = FakePlatform()..starting = Completer<int>();
      final controller = CaptureController(platform);
      await controller.initialize();
      final starting = controller.start();
      final stopping = controller.stop();
      expect(controller.phase, CapturePhase.stopping);
      platform.starting!.complete(9);
      await Future.wait([starting, stopping]);
      expect(controller.phase, CapturePhase.idle);
      expect(controller.textureId, isNull);
      platform.starting = null;
      await controller.start();
      expect(controller.running, isTrue);
      expect(controller.textureId, 7);
      await controller.stop();
      controller.dispose();
    },
  );

  test('a snapshot arriving after stop cannot update a new session', () async {
    final platform = FakePlatform()..reading = Completer<CaptureSnapshot>();
    final controller = CaptureController(platform);
    await controller.initialize();
    await controller.start();
    await Future<void>.delayed(const Duration(milliseconds: 550));
    await controller.stop();
    await controller.start();
    platform.reading!.complete(
      const CaptureSnapshot(frames: 99, width: 800, height: 600),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.snapshot, isNull);
    expect(controller.running, isTrue);
    await controller.stop();
    controller.dispose();
  });

  test(
    'cancelling selection keeps the previous region and stays idle',
    () async {
      final platform = FakePlatform()
        ..selection = const CaptureRegion(10, 20, 300, 100);
      final controller = CaptureController(platform);
      await controller.initialize();
      await controller.selectRegion();
      final previous = controller.region;
      platform.selection = null;
      await controller.selectRegion();
      expect(controller.region, same(previous));
      expect(controller.running, isFalse);
      controller.dispose();
    },
  );
}
