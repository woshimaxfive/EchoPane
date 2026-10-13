import 'package:flutter/services.dart';

class CaptureDisplay {
  const CaptureDisplay({
    required this.id,
    required this.name,
    required this.width,
    required this.height,
    required this.primary,
    this.x = 0,
    this.y = 0,
  });

  final int id;
  final String name;
  final int width;
  final int height;
  final bool primary;
  final int x, y;

  factory CaptureDisplay.fromMap(Map<Object?, Object?> map) => CaptureDisplay(
    id: map['id']! as int,
    name: map['name']! as String,
    width: map['width']! as int,
    height: map['height']! as int,
    primary: map['primary']! as bool,
    x: map['x'] as int? ?? 0,
    y: map['y'] as int? ?? 0,
  );
}

/// Coordinates are physical pixels relative to the selected display.
class CaptureRegion {
  const CaptureRegion(this.x, this.y, this.width, this.height);

  final int x;
  final int y;
  final int width;
  final int height;

  Map<String, int> toMap() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  factory CaptureRegion.fromMap(Map<Object?, Object?> map) => CaptureRegion(
    map['x']! as int,
    map['y']! as int,
    map['width']! as int,
    map['height']! as int,
  );
}

class CaptureSnapshot {
  const CaptureSnapshot({
    required this.frames,
    required this.width,
    required this.height,
    this.error,
    this.displayId,
    this.region,
    this.sessionExclusion,
  });

  final int frames;
  final int width;
  final int height;
  final String? error;
  final int? displayId;
  final CaptureRegion? region;
  final bool? sessionExclusion;
}

class CaptureTargetWindow {
  const CaptureTargetWindow({
    required this.id,
    required this.processId,
    required this.title,
    required this.displayId,
  });
  final int id, processId, displayId;
  final String title;
  factory CaptureTargetWindow.fromMap(Map<Object?, Object?> map) =>
      CaptureTargetWindow(
        id: map['id']! as int,
        processId: map['processId']! as int,
        title: map['title']! as String,
        displayId: map['displayId']! as int,
      );
}

abstract interface class WindowCapturePlatform {
  Future<List<CaptureTargetWindow>> windows();
  Future<CaptureRegion?> selectWindowRegion(CaptureTargetWindow window);
  Future<int> startWindow(CaptureTargetWindow window, CaptureRegion? region);
}

abstract interface class CapturePlatform {
  Future<List<CaptureDisplay>> displays();
  Future<CaptureRegion?> selectRegion(int displayId);
  Future<int> start(int displayId, CaptureRegion? region);
  Future<void> stop();
  Future<CaptureSnapshot> snapshot();
}

class WindowsCapturePlatform implements CapturePlatform, WindowCapturePlatform {
  static const channel = MethodChannel('echopane/capture');
  @override
  Future<List<CaptureTargetWindow>> windows() async =>
      (await channel.invokeListMethod<Object?>('windows') ?? [])
          .map(
            (value) =>
                CaptureTargetWindow.fromMap(value! as Map<Object?, Object?>),
          )
          .toList();
  @override
  Future<CaptureRegion?> selectWindowRegion(CaptureTargetWindow window) async {
    final value = await channel.invokeMapMethod<Object?, Object?>(
      'selectRegion',
      {
        'displayId': window.displayId,
        'windowId': window.id,
        'processId': window.processId,
      },
    );
    return value == null ? null : CaptureRegion.fromMap(value);
  }

  @override
  Future<int> startWindow(
    CaptureTargetWindow window,
    CaptureRegion? region,
  ) async {
    final value = await channel.invokeMethod<int>('start', {
      'displayId': window.displayId,
      'windowId': window.id,
      'processId': window.processId,
      if (region != null) 'region': region.toMap(),
    });
    if (value == null) throw StateError('未能创建窗口预览');
    return value;
  }

  @override
  Future<List<CaptureDisplay>> displays() async {
    final values = await channel.invokeListMethod<Object?>('displays');
    return (values ?? [])
        .map((value) => CaptureDisplay.fromMap(value! as Map<Object?, Object?>))
        .toList();
  }

  @override
  Future<CaptureRegion?> selectRegion(int displayId) async {
    final value = await channel.invokeMapMethod<Object?, Object?>(
      'selectRegion',
      {'displayId': displayId},
    );
    return value == null ? null : CaptureRegion.fromMap(value);
  }

  @override
  Future<int> start(int displayId, CaptureRegion? region) async {
    final result = await channel.invokeMethod<int>('start', {
      'displayId': displayId,
      if (region != null) 'region': region.toMap(),
    });
    if (result == null) throw StateError('未能创建屏幕预览');
    return result;
  }

  @override
  Future<void> stop() => channel.invokeMethod<void>('stop');

  @override
  Future<CaptureSnapshot> snapshot() async {
    final result = await channel.invokeMapMethod<Object?, Object?>('snapshot');
    if (result == null) throw StateError('未能读取捕获状态');
    return CaptureSnapshot(
      frames: result['frames']! as int,
      width: result['width']! as int,
      height: result['height']! as int,
      error: result['error'] as String?,
      displayId: result['displayId'] as int?,
      sessionExclusion: result['sessionExclusion'] as bool?,
      region: result['region'] == null
          ? null
          : CaptureRegion.fromMap(result['region']! as Map<Object?, Object?>),
    );
  }
}
