import 'package:flutter/services.dart';

class OverlayWindowState {
  const OverlayWindowState({
    this.visible = false,
    this.locked = false,
    this.hotkey = false,
    this.width = 720,
    this.height = 220,
    this.dpi = 96,
  });
  final bool visible;
  final bool locked;
  final bool hotkey;
  final int width;
  final int height;
  final int dpi;
  factory OverlayWindowState.fromMap(Map<Object?, Object?> value) =>
      OverlayWindowState(
        visible: value['visible'] == true,
        locked: value['locked'] == true,
        hotkey: value['hotkey'] == true,
        width: value['width'] as int? ?? 720,
        height: value['height'] as int? ?? 220,
        dpi: value['dpi'] as int? ?? 96,
      );
}

abstract interface class OverlayPlatform {
  void listen(void Function(OverlayWindowState)? listener);
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool locked,
    bool restore = false,
    bool allowCapture = false,
    int? displayId,
  });
  Future<bool> present(int width, int height, Uint8List rgba);
}

class WindowsOverlayPlatform implements OverlayPlatform {
  static const channel = MethodChannel('echopane/subtitle_overlay');
  @override
  void listen(void Function(OverlayWindowState)? listener) {
    channel.setMethodCallHandler(
      listener == null
          ? null
          : (call) async {
              if (call.method == 'state') {
                listener(
                  OverlayWindowState.fromMap(
                    call.arguments as Map<Object?, Object?>,
                  ),
                );
              }
            },
    );
  }

  @override
  Future<OverlayWindowState> configure({
    required bool visible,
    required bool locked,
    bool restore = false,
    bool allowCapture = false,
    int? displayId,
  }) async => OverlayWindowState.fromMap(
    await channel.invokeMapMethod<Object?, Object?>('configure', {
          'visible': visible,
          'locked': locked,
          'restore': restore,
          'allowCapture': allowCapture,
          'displayId': ?displayId,
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
