import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../ocr/model_store.dart';
import '../subtitles/caption_source.dart';

const audioModelFiles = [
  OcrModelFile(
    'ggml-base.bin',
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
    '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe',
    147951465,
  ),
  OcrModelFile(
    'ggml-silero-v6.2.0.bin',
    'https://huggingface.co/ggml-org/whisper-vad/resolve/c5c26827b67dfd053856f92e824e14fdcc123daf/ggml-silero-v6.2.0.bin',
    '2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987',
    885098,
  ),
];

class PlaybackDevice {
  const PlaybackDevice(this.id, this.name, this.isDefault);
  final String id;
  final String name;
  final bool isDefault;
}

abstract interface class AudioPlatform {
  Future<void> refresh();
  Future<void> start(String directory, String device, String language);
  Future<void> stop();
  Future<Map<Object?, Object?>> snapshot();
}

class WindowsAudioPlatform implements AudioPlatform {
  static const channel = MethodChannel('echopane/audio');
  @override
  Future<void> refresh() => channel.invokeMethod<void>('refresh');
  @override
  Future<void> start(String directory, String device, String language) =>
      channel.invokeMethod<void>('start', {
        'directory': directory,
        'device': device,
        'language': language,
      });
  @override
  Future<void> stop() => channel.invokeMethod<void>('stop');
  @override
  Future<Map<Object?, Object?>> snapshot() async =>
      await channel.invokeMapMethod<Object?, Object?>('snapshot') ?? {};
}

class AudioController extends CaptionSource {
  AudioController(this.platform, {OcrModelStore? models})
    : models =
          models ??
          OcrModelStore(
            directory:
                '${Platform.environment['LOCALAPPDATA']}/EchoPane/models/whisper-base',
            files: audioModelFiles,
          );
  final AudioPlatform platform;
  final OcrModelStore models;
  List<PlaybackDevice> devices = [];
  String deviceId = '';
  String language = 'auto';
  String detectedLanguage = '';
  List<String> lines = [];
  bool running = false, starting = false, stopping = false, recognizing = false;
  String? error;
  double level = 0;
  int samples = 0, dropped = 0, durationMs = 0;
  int _generation = 0, _nativeSession = 0, _nativeRevision = 0;
  bool _wanted = false, _polling = false, _disposed = false;
  Timer? _timer;
  Future<void>? _pendingStart;
  bool get busy => starting || stopping;
  String get text => lines.join('\n');
  @override
  bool get captionRunning => running;
  @override
  String? get captionError => error;
  @override
  List<String> get captionLines => lines;
  @override
  String get captionSession => '$_generation:$_nativeSession';
  @override
  int get captionRevision => _nativeRevision;
  @override
  int? get captionDisplayId => null;
  @override
  String get waitingCaption => '等待播放设备中的语音…';

  Future<void> initialize() async {
    await refresh();
    _timer ??= Timer.periodic(const Duration(milliseconds: 300), (_) => poll());
    await models.check();
  }

  Future<void> refresh() async {
    try {
      await platform.refresh();
      await poll();
    } catch (_) {
      error = '无法读取播放设备，请重试';
      _notify();
    }
  }

  Future<void> selectDevice(String value) async {
    if (value == deviceId || busy) return;
    await stop();
    deviceId = value;
    _notify();
  }

  Future<void> selectLanguage(String value) async {
    if (!{'auto', 'en', 'ja'}.contains(value) || value == language || busy) {
      return;
    }
    await stop();
    language = value;
    _notify();
  }

  Future<void> start() async {
    if (_disposed || busy || running || models.phase != ModelPhase.ready) {
      return;
    }
    final token = ++_generation;
    _wanted = true;
    starting = true;
    error = null;
    lines = [];
    dropped = samples = durationMs = 0;
    detectedLanguage = '';
    _notify();
    final request = platform.start(models.directory, deviceId, language);
    _pendingStart = request;
    try {
      await request;
      if (_disposed || token != _generation) return;
      await poll();
    } catch (_) {
      if (!_disposed && token == _generation) {
        _wanted = starting = false;
        error = '无法启动系统音频，请检查播放设备和本地模型';
        _notify();
      }
    } finally {
      if (identical(_pendingStart, request)) _pendingStart = null;
    }
  }

  Future<void> stop() async {
    if (_disposed || stopping) return;
    ++_generation;
    _wanted = starting = running = recognizing = false;
    stopping = true;
    lines = [];
    level = 0;
    error = null;
    _notify();
    try {
      try {
        await _pendingStart;
      } catch (_) {
        /* Still stop the native session. */
      }
      await platform.stop();
    } catch (_) {
      error = '停止系统音频失败，请重试';
    } finally {
      stopping = false;
      _notify();
    }
  }

  Future<void> poll() async {
    if (_disposed || _polling) return;
    _polling = true;
    final token = _generation;
    try {
      final state = await platform.snapshot();
      if (_disposed || token != _generation) return;
      devices = [
        for (final value in (state['devices'] as List? ?? []))
          if (value is Map)
            PlaybackDevice(
              value['id'] as String,
              value['name'] as String,
              value['default'] == true,
            ),
      ];
      if (_wanted) {
        final nativeError = state['error'] as String? ?? '';
        if (nativeError.isNotEmpty) {
          _wanted = running = starting = recognizing = false;
          lines = [];
          level = 0;
          error = '系统音频或语音识别暂不可用，请检查设备后重新开始';
        } else {
          _nativeSession = (state['session'] as num?)?.toInt() ?? 0;
          _nativeRevision = (state['revision'] as num?)?.toInt() ?? 0;
          starting = state['loading'] == true;
          running = state['running'] == true;
          recognizing = state['recognizing'] == true;
          lines = List<String>.from(state['lines'] as List? ?? []);
          level = ((state['level'] as num?)?.toDouble() ?? 0).clamp(0, 1);
          samples = (state['samples'] as num?)?.toInt() ?? 0;
          dropped = (state['dropped'] as num?)?.toInt() ?? 0;
          durationMs = (state['durationMs'] as num?)?.toInt() ?? 0;
          detectedLanguage = state['language'] as String? ?? '';
        }
      }
      _notify();
    } catch (_) {
      if (token == _generation && !_disposed) {
        if (_wanted) {
          _wanted = running = starting = recognizing = false;
          lines = [];
          level = 0;
          try {
            await platform.stop();
          } catch (_) {
            // Retain the state-read failure when the native channel is unavailable.
          }
        }
        error = '无法读取系统音频状态，请重试';
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
    super.dispose();
  }
}
