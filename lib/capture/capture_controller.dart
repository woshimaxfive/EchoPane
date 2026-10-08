import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'capture_platform.dart';

enum CapturePhase { idle, selecting, starting, running, stopping, failed }

class CaptureController extends ChangeNotifier {
  CaptureController(this.platform);

  final CapturePlatform platform;
  List<CaptureDisplay> displays = [];
  CaptureDisplay? display;
  CaptureRegion? region;
  CapturePhase phase = CapturePhase.idle;
  CaptureSnapshot? snapshot;
  int? textureId;
  String? error;
  Timer? _timer;
  int _generation = 0;
  bool _polling = false;
  bool _disposed = false;
  Future<void>? _starting;

  bool get busy =>
      phase == CapturePhase.selecting ||
      phase == CapturePhase.starting ||
      phase == CapturePhase.stopping;
  bool get running => phase == CapturePhase.running;

  Future<void> initialize() async {
    try {
      displays = await platform.displays();
      if (displays.isEmpty) throw StateError('没有找到可用的显示器');
      display = displays.firstWhere(
        (d) => d.primary,
        orElse: () => displays.first,
      );
    } catch (exception) {
      error = _message(exception);
      phase = CapturePhase.failed;
    }
    _notify();
  }

  Future<void> chooseDisplay(CaptureDisplay value) async {
    if (busy) return;
    await stop();
    if (_disposed) return;
    display = value;
    region = null;
    _notify();
  }

  Future<void> selectRegion() async {
    final current = display;
    if (current == null || busy) return;
    await stop();
    phase = CapturePhase.selecting;
    error = null;
    _notify();
    try {
      final chosen = await platform.selectRegion(current.id);
      if (!_disposed && chosen != null) region = chosen;
      phase = CapturePhase.idle;
    } catch (exception) {
      phase = CapturePhase.failed;
      error = _message(exception);
    }
    _notify();
  }

  Future<void> useFullDisplay() async {
    if (busy) return;
    await stop();
    region = null;
    _notify();
  }

  Future<void> start() {
    if (_starting != null) return _starting!;
    final operation = _start();
    _starting = operation.whenComplete(() => _starting = null);
    return _starting!;
  }

  Future<void> _start() async {
    final current = display;
    if (current == null || busy || running) return;
    final generation = ++_generation;
    phase = CapturePhase.starting;
    error = null;
    snapshot = null;
    _notify();
    try {
      final id = await platform.start(current.id, region);
      if (_disposed || generation != _generation) {
        await platform.stop();
        return;
      }
      textureId = id;
      phase = CapturePhase.running;
      _timer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _poll(generation),
      );
    } catch (exception) {
      if (generation == _generation && !_disposed) {
        phase = CapturePhase.failed;
        error = _message(exception);
      }
    }
    _notify();
  }

  Future<void> _poll(int generation) async {
    if (_polling || _disposed || generation != _generation) return;
    _polling = true;
    try {
      final value = await platform.snapshot();
      if (!_disposed && generation == _generation) {
        snapshot = value;
        if (value.error != null) {
          await stop();
          phase = CapturePhase.failed;
          error = value.error;
        }
        _notify();
      }
    } catch (exception) {
      if (!_disposed && generation == _generation) {
        await stop();
        phase = CapturePhase.failed;
        error = _message(exception);
        _notify();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    textureId = null;
    snapshot = null;
    phase = CapturePhase.stopping;
    _notify();
    try {
      await _starting;
      await platform.stop();
      phase = CapturePhase.idle;
      error = null;
    } catch (exception) {
      phase = CapturePhase.failed;
      error = _message(exception);
    }
    _notify();
  }

  String _message(Object exception) => exception is PlatformException
      ? exception.message ?? '屏幕捕获不可用，请重新开始'
      : exception.toString();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    super.dispose();
  }
}
