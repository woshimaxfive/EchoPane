import 'package:flutter/services.dart';

import '../capture/capture_platform.dart';
import '../subtitles/overlay_platform.dart';

abstract interface class ScreenOverlayPlatform {
  void listen(void Function(OverlayWindowState)? listener);
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool allowCapture,
    required int displayId,
    CaptureRegion? region,
  });
  Future<bool> present(int width, int height, Uint8List rgba);
}

class WindowsScreenOverlayPlatform implements ScreenOverlayPlatform {
  static const channel = MethodChannel('echopane/screen_overlay');
  @override
  void listen(void Function(OverlayWindowState)? listener) {
    channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method == 'state') {
                final value = call.arguments as Map<Object?, Object?>;
                if (value['dismissed'] == true) {
                  listener(OverlayWindowState.fromMap(value));
                }
              }
            },
    );
  }

  @override
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool allowCapture,
    required int displayId,
    CaptureRegion? region,
  }) async => OverlayWindowState.fromMap(
    await channel.invokeMapMethod<Object?, Object?>('configure', {
          'visible': visible,
          'allowCapture': allowCapture,
          'displayId': displayId,
          'locked': true,
          'restore': false,
          if (region != null) 'region': region.toMap(),
        }) ??
        {},
  );
  @override
  Future<bool> present(int width, int height, Uint8List rgba) async =>
      await channel.invokeMethod<bool>('frame', {
        'width': width,
        'height': height,
        'rgba': rgba,
      }) ??
      false;
}
