import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../capture/capture_controller.dart';
import '../capture/capture_platform.dart';
import 'model_store.dart';

class OcrLine {
  const OcrLine(this.text, this.confidence);
  final String text;
  final double confidence;
}

abstract interface class OcrPlatform {
  Future<void> load(String directory);
  Future<Map<Object?, Object?>> snapshot();
}

class WindowsOcrPlatform implements OcrPlatform {
  @override
  Future<void> load(String directory) => WindowsCapturePlatform.channel
      .invokeMethod<void>('ocrLoad', {'directory': directory});
  @override
  Future<Map<Object?, Object?>> snapshot() async =>
      await WindowsCapturePlatform.channel.invokeMapMethod<Object?, Object?>(
        'ocrSnapshot',
      ) ??
      {};
}

class OcrController extends ChangeNotifier {
  OcrController(this.capture, this.models, this.platform) {
    capture.addListener(_captureChanged);
    models.addListener(_modelsChanged);
    _timer = Timer.periodic(const Duration(milliseconds: 400), (_) => poll());
    _modelsChanged();
  }

  final CaptureController capture;
  final OcrModelStore models;
  final OcrPlatform platform;
  Timer? _timer;
  bool ready = false;
  bool loading = false;
  String? error;
  List<OcrLine> lines = [];
  int durationMs = 0;
  int recognized = 0;
  int skipped = 0;
  bool _polling = false;
  bool _requested = false;
  bool _wasRunning = false;
  bool _disposed = false;
  int _generation = 0;
  String get text => lines.map((line) => line.text).join('\n');

  void _captureChanged() {
    if (capture.running != _wasRunning) {
      ++_generation;
      _wasRunning = capture.running;
      lines = [];
      error = null;
      recognized = 0;
      skipped = 0;
      durationMs = 0;
      _notify();
    }
  }

  void _modelsChanged() {
    if (models.phase == ModelPhase.ready && !_requested) unawaited(load());
  }

  Future<void> load() async {
    if (loading || models.phase != ModelPhase.ready) return;
    _requested = true;
    loading = true;
    ready = false;
    error = null;
    _notify();
    try {
      await platform.load(models.directory);
    } catch (_) {
      loading = false;
      error = '无法加载文字识别，请重试';
      _requested = false;
      _notify();
    }
  }

  Future<void> poll() async {
    if (_polling || _disposed || !_requested) return;
    _polling = true;
    final generation = _generation;
    try {
      final state = await platform.snapshot();
      if (_disposed) return;
      ready = state['ready'] == true;
      loading = state['loading'] == true;
      if (generation == _generation) error = state['error'] as String?;
      if (generation == _generation && capture.running) {
        lines = (state['lines'] as List<Object?>? ?? []).map((value) {
          final map = value! as Map<Object?, Object?>;
          return OcrLine(
            map['text']! as String,
            (map['confidence']! as num).toDouble(),
          );
        }).toList();
        durationMs = state['durationMs'] as int? ?? 0;
        recognized = state['recognized'] as int? ?? 0;
        skipped = state['skipped'] as int? ?? 0;
      }
      _notify();
    } on PlatformException catch (exception) {
      if (!_disposed && generation == _generation) {
        error = exception.message ?? '文字识别不可用，请重试';
        loading = false;
        _notify();
      }
    } catch (_) {
      if (!_disposed && generation == _generation) {
        error = '无法读取识别结果，请重试';
        loading = false;
        _notify();
      }
    } finally {
      _polling = false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    capture.removeListener(_captureChanged);
    models.removeListener(_modelsChanged);
    super.dispose();
  }
}
