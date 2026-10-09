import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../ocr/model_store.dart';
import '../subtitles/caption_source.dart';
import 'streaming_audio.dart';

enum AudioBackend { local, cloud }

abstract interface class StreamingAudioPlatform {
  Future<void> startStream(String device);
}

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

class WindowsAudioPlatform implements AudioPlatform, StreamingAudioPlatform {
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
  Future<void> startStream(String device) =>
      channel.invokeMethod<void>('startStream', {'device': device});
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
  AudioBackend backend = AudioBackend.local;
  Future<AudioStreamSession> Function()? openStream;
  String Function()? streamTarget;
  AudioStreamSession? _stream;
  StreamSubscription<SpeechUpdate>? _speechSubscription;
  final _speechIds = <String>{};
  String _activeSpeech = '', _target = '';
  final _confirmed = <ConfirmedCaption>[];
  bool provisional = false;
  bool _captureStarted = false;
  bool get isCloud => backend == AudioBackend.cloud;
  String detectedLanguage = '';
  List<String> lines = [];
  bool running = false, starting = false, stopping = false, recognizing = false;
  String? error;
  double level = 0;
  int samples = 0, dropped = 0, durationMs = 0;
  int _generation = 0, _nativeSession = 0, _nativeRevision = 0;
  bool _wanted = false, _polling = false, _disposed = false;
  Completer<void>? _pollDone;
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
  List<String>? get captionTranslations => isCloud ? _directTranslations : null;
  List<String> _directTranslations = [];
  @override
  List<ConfirmedCaption>? get captionConfirmed =>
      isCloud ? List.unmodifiable(_confirmed) : null;
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
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), (_) => poll());
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

  Future<void> selectBackend(AudioBackend value) async {
    if (_disposed || busy || backend == value) return;
    await stop();
    backend = value;
    _notify();
  }

  void _clearSpeech() {
    _captureStarted = false;
    _confirmed.clear();
    _speechIds.clear();
    _activeSpeech = '';
    _directTranslations = [];
    provisional = false;
  }

  void _speech(SpeechUpdate update, int token) {
    if (_disposed || token != _generation) return;
    if (_speechIds.add(update.id)) _activeSpeech = update.id;
    while (_speechIds.length > 256) {
      _speechIds.remove(_speechIds.first);
    }
    if (update.isFinal && !_confirmed.any((c) => c.id == update.id)) {
      _confirmed.add(
        ConfirmedCaption(update.id, update.source, update.translation, _target),
      );
      if (_confirmed.length > 64) _confirmed.removeAt(0);
    }
    if (_activeSpeech == update.id) {
      lines = update.source.trim().isEmpty ? [] : [update.source];
      _directTranslations = lines.isEmpty ? [] : [update.translation];
      detectedLanguage = update.language;
      provisional = !update.isFinal;
      ++_nativeRevision;
    }
    _notify();
  }

  Future<void> _streamFailed(Object failure, int token) async {
    if (_disposed || token != _generation || stopping) return;
    ++_generation;
    _wanted = starting = running = recognizing = false;
    lines = [];
    level = 0;
    _clearSpeech();
    error = failure is AudioStreamFailure ? failure.message : '实时语音连接中断，请重新开始';
    final session = _stream;
    _stream = null;
    await _speechSubscription?.cancel();
    _speechSubscription = null;
    await session?.cancel();
    try {
      await platform.stop();
    } catch (_) {
      /* Preserve the original failure. */
    }
    _notify();
  }

  Future<void> _startStream(int token) async {
    final factory = openStream;
    if (factory == null || platform is! StreamingAudioPlatform) {
      throw const AudioStreamFailure('当前平台尚不支持实时语音');
    }
    _target = streamTarget?.call() ?? '';
    final session = await factory();
    if (_disposed || token != _generation) {
      await session.cancel();
      return;
    }
    _stream = session;
    _speechSubscription = session.updates.listen(
      (update) => _speech(update, token),
      onError: (Object failure) => unawaited(_streamFailed(failure, token)),
    );
    await session.ready;
    if (_disposed || token != _generation) {
      await session.cancel();
      return;
    }
    await (platform as StreamingAudioPlatform).startStream(deviceId);
    _captureStarted = token == _generation && !_disposed;
  }

  Future<void> start() async {
    if (_disposed ||
        busy ||
        running ||
        (!isCloud && models.phase != ModelPhase.ready)) {
      return;
    }
    final token = ++_generation;
    _wanted = true;
    starting = true;
    error = null;
    lines = [];
    dropped = samples = durationMs = 0;
    detectedLanguage = '';
    _clearSpeech();
    _notify();
    final request = isCloud
        ? _startStream(token)
        : platform.start(models.directory, deviceId, language);
    _pendingStart = request;
    try {
      await request;
      if (_disposed || token != _generation) return;
      await poll();
    } catch (failure) {
      if (!_disposed && token == _generation) {
        _wanted = starting = false;
        error = failure is AudioStreamFailure
            ? failure.message
            : '无法启动系统音频，请检查播放设备和识别服务';
        await _speechSubscription?.cancel();
        _speechSubscription = null;
        await _stream?.cancel();
        _stream = null;
        _notify();
      }
    } finally {
      if (identical(_pendingStart, request)) _pendingStart = null;
    }
  }

  Future<void> stop() async {
    if (_disposed || stopping) return;
    if (isCloud && running && !starting) {
      stopping = true;
      _notify();
      try {
        await _pollDone?.future.timeout(const Duration(seconds: 3));
        _wanted = false;
        // Drain the final captured PCM before stopping the device, then flush the server.
        final state = await platform.snapshot();
        final pcm = state['pcm'];
        if (pcm is Uint8List && pcm.isNotEmpty) _stream?.addPcm(pcm);
        await platform.stop();
        await _stream?.finish();
        await Future<void>.delayed(Duration.zero);
      } catch (failure) {
        error = failure is AudioStreamFailure
            ? failure.message
            : '最后一段未完整完成，请重新开始';
        try {
          await platform.stop();
        } catch (_) {
          /* Keep drain failure. */
        }
      } finally {
        _wanted = false;
        ++_generation;
        running = starting = recognizing = false;
        await _speechSubscription?.cancel();
        _speechSubscription = null;
        await _stream?.cancel();
        _stream = null;
        lines = [];
        level = 0;
        _clearSpeech();
        stopping = false;
        _notify();
      }
      return;
    }
    ++_generation;
    _wanted = starting = running = recognizing = false;
    stopping = true;
    lines = [];
    _clearSpeech();
    level = 0;
    error = null;
    _notify();
    try {
      await _stream?.cancel();
      try {
        await _pendingStart;
      } catch (_) {
        /* Still stop the native session. */
      }
      await platform.stop();
      await _speechSubscription?.cancel();
      _speechSubscription = null;
      await _stream?.cancel();
      _stream = null;
    } catch (_) {
      error = '停止系统音频失败，请重试';
    } finally {
      stopping = false;
      _notify();
    }
  }

  Future<void> poll() async {
    if (_disposed || _polling || stopping) return;
    _polling = true;
    final complete = Completer<void>();
    _pollDone = complete;
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
        if (isCloud && !_captureStarted) return;
        final nativeError = state['error'] as String? ?? '';
        if (nativeError.isNotEmpty) {
          if (isCloud) {
            unawaited(
              _streamFailed(
                const AudioStreamFailure('系统音频设备暂不可用，请检查后重新开始'),
                token,
              ),
            );
            return;
          }
          _wanted = running = starting = recognizing = false;
          lines = [];
          level = 0;
          error = '系统音频或语音识别暂不可用，请检查设备后重新开始';
        } else {
          final nextSession = (state['session'] as num?)?.toInt() ?? 0;
          final nextDrops = (state['dropped'] as num?)?.toInt() ?? 0;
          if (isCloud &&
              running &&
              (nextSession != _nativeSession || nextDrops > 0)) {
            unawaited(
              _streamFailed(
                const AudioStreamFailure('播放设备已变化或音频有丢失，请重新开始以保持字幕对应'),
                token,
              ),
            );
            return;
          }
          _nativeSession = (state['session'] as num?)?.toInt() ?? 0;
          if (!isCloud) {
            _nativeRevision = (state['revision'] as num?)?.toInt() ?? 0;
          }
          starting = state['loading'] == true;
          running = state['running'] == true;
          recognizing = state['recognizing'] == true;
          if (!isCloud) {
            lines = List<String>.from(state['lines'] as List? ?? []);
          }
          level = ((state['level'] as num?)?.toDouble() ?? 0).clamp(0, 1);
          samples = (state['samples'] as num?)?.toInt() ?? 0;
          dropped = (state['dropped'] as num?)?.toInt() ?? 0;
          durationMs = (state['durationMs'] as num?)?.toInt() ?? 0;
          if (!isCloud) detectedLanguage = state['language'] as String? ?? '';
          final pcm = state['pcm'];
          if (isCloud && pcm is Uint8List && pcm.isNotEmpty) {
            _stream?.addPcm(pcm);
          }
        }
      }
      _notify();
    } catch (_) {
      if (token == _generation && !_disposed) {
        if (isCloud) {
          unawaited(
            _streamFailed(const AudioStreamFailure('系统音频或实时发送失败，请重新开始'), token),
          );
          return;
        }
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
      complete.complete();
      if (identical(_pollDone, complete)) _pollDone = null;
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
    unawaited(_speechSubscription?.cancel());
    unawaited(_stream?.cancel());
    unawaited(platform.stop().catchError((Object _) {}));
    super.dispose();
  }
}
