import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../translation/settings.dart';
import 'streaming_audio.dart';

const bailianAudioModel = 'qwen3.5-livetranslate-flash-realtime';

Uri bailianAudioEndpoint(TranslationSettings settings) {
  final host = settings.endpoint.host;
  if (host != 'dashscope.aliyuncs.com' &&
      !RegExp(r'^[a-zA-Z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$')
          .hasMatch(host)) {
    throw const AudioStreamFailure('实时语音需要百炼北京地址，请先在翻译设置中保存北京预设和 Key');
  }
  if (settings.endpoint.hasPort && settings.endpoint.port != 443) {
    throw const AudioStreamFailure('实时语音地址必须使用 HTTPS 默认端口');
  }
  return Uri(
    scheme: 'wss',
    host: host,
    path: '/api-ws/v1/realtime',
    queryParameters: {'model': bailianAudioModel},
  );
}

String bailianAudioTarget(String value) {
  if (!translationLanguages.containsKey(value) || value == 'auto') {
    throw const AudioStreamFailure('请选择有效的目标语言');
  }
  if (value == 'zh-Hant') {
    throw const AudioStreamFailure('实时语音暂不支持指定繁体中文，请选择简体中文或其他目标语言');
  }
  return value == 'zh-Hans' ? 'zh' : value;
}

class _Turn {
  _Turn(this.id);
  final String id;
  String source = '', translation = '', language = '';
  bool sourceFinal = false, textDone = false, responseDone = false;
  SpeechUpdate get update => SpeechUpdate(
    id: id,
    source: source,
    translation: translation,
    language: language,
    isFinal:
        sourceFinal &&
        textDone &&
        responseDone &&
        source.trim().isNotEmpty &&
        translation.trim().isNotEmpty,
  );
}

/// Vendor event IDs and conversation links stay inside this adapter.
class BailianAudioDecoder {
  final _turns = <String, _Turn>{};
  final _parents = <String, String>{};
  final _responseItems = <String, String>{};

  _Turn? _sourceFor(String item) {
    final visited = <String>{};
    while (item.isNotEmpty && visited.add(item)) {
      final turn = _turns[item];
      if (turn != null) return turn;
      item = _parents[item] ?? '';
    }
    return null;
  }

  List<SpeechUpdate> accept(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'conversation.item.created') {
      final item = event['item'] as Map?;
      final id = item?['id'] as String? ?? '';
      final content = item?['content'] as List? ?? [];
      if (id.isEmpty) return [];
      if (content.any((c) => c is Map && c['type'] == 'input_audio')) {
        _turns.putIfAbsent(id, () => _Turn(id));
      }
      final previous = event['previous_item_id'] as String?;
      if (previous != null) _parents[id] = previous;
      _trim();
      return [];
    }
    final item = event['item_id'] as String? ?? '';
    if (type == 'conversation.item.input_audio_transcription.text' ||
        type == 'conversation.item.input_audio_transcription.completed') {
      if (item.isEmpty) return [];
      final turn = _turns.putIfAbsent(item, () => _Turn(item));
      if (type == 'conversation.item.input_audio_transcription.completed') {
        turn.source = event['transcript'] as String? ?? '';
        turn.sourceFinal = true;
      } else if (!turn.sourceFinal) {
        // These are replaceable snapshots, not append-only token deltas.
        turn.source = '${event['text'] ?? ''}${event['stash'] ?? ''}';
      }
      turn.language = event['language'] as String? ?? turn.language;
      _trim();
      return [turn.update];
    }
    if (type == 'response.text.text' || type == 'response.text.done') {
      final turn = _sourceFor(item);
      if (turn == null) {
        throw const AudioStreamFailure('实时译文无法对应原文，请重新开始');
      }
      final response = event['response_id'] as String? ?? '';
      if (response.isNotEmpty) _responseItems[response] = item;
      if (type == 'response.text.done') {
        turn.translation = event['text'] as String? ?? '';
        turn.textDone = true;
      } else if (!turn.textDone) {
        turn.translation = '${event['text'] ?? ''}${event['stash'] ?? ''}';
      }
      return [turn.update];
    }
    if (type == 'response.done') {
      final response = event['response'] as Map?;
      final id = response?['id'] as String? ?? '';
      final turn = _sourceFor(_responseItems[id] ?? '');
      if (turn == null) return [];
      turn.responseDone = response?['status'] == 'completed';
      if (!turn.responseDone) {
        throw const AudioStreamFailure('实时翻译未完整完成，请重新开始');
      }
      return [turn.update];
    }
    return [];
  }

  void _trim() {
    // Retain recent links for out-of-order final events without unbounded growth.
    while (_turns.length > 128) {
      final oldest = _turns.keys.first;
      _turns.remove(oldest);
      _parents.removeWhere((k, v) => k == oldest || v == oldest);
      _responseItems.removeWhere((k, v) => !_parents.containsKey(v));
    }
    while (_parents.length > 512) {
      _parents.remove(_parents.keys.first);
    }
  }
}

class BailianAudioSession implements AudioStreamSession {
  BailianAudioSession(
    TranslationSettings settings,
    String key, {
    String source = 'auto',
  }) {
    _ready = _connect(settings, key, source);
  }
  final _controller = StreamController<SpeechUpdate>();
  final _decoder = BailianAudioDecoder();
  final _configured = Completer<void>(), _finished = Completer<void>();
  final _client = HttpClient();
  WebSocket? _socket;
  late final Future<void> _ready;
  bool _cancelled = false, _finishing = false, _failed = false;
  int _event = 0;
  final _outgoing = Queue<String>();
  bool _sending = false;
  @override
  Stream<SpeechUpdate> get updates => _controller.stream;
  @override
  Future<void> get ready => _ready;

  Future<void> _connect(
    TranslationSettings settings,
    String key,
    String source,
  ) async {
    try {
      if (key.isEmpty) throw const AudioStreamFailure('请先在翻译设置中保存百炼 Key');
      final endpoint = bailianAudioEndpoint(settings);
      final target = bailianAudioTarget(settings.target);
      _socket = await WebSocket.connect(
        endpoint.toString(),
        headers: {'Authorization': 'Bearer $key'},
        customClient: _client,
      ).timeout(const Duration(seconds: 20));
      if (_cancelled) {
        await _socket!.close();
        return;
      }
      _socket!.pingInterval = const Duration(seconds: 15);
      _socket!.listen(
        _receive,
        onError: (_) => _fail('实时语音连接中断，请重新开始'),
        onDone: () {
          if (!_cancelled && !_finished.isCompleted) _fail('实时语音连接已断开，请重新开始');
        },
      );
      _send('session.update', {
        'session': {
          'modalities': ['text'],
          'input_audio_format': 'pcm',
          'sample_rate': 16000,
          'translation': {'language': target},
          'input_audio_transcription': {
            'model': 'qwen3-asr-flash-realtime',
            if (source != 'auto') 'language': source,
          },
          'turn_detection': {
            'type': 'server_vad',
            'threshold': 0.2,
            'silence_duration_ms': 640,
          },
        },
      });
      await _configured.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      await cancel();
      throw e is AudioStreamFailure
          ? e
          : const AudioStreamFailure('无法连接百炼实时语音，请检查网络、Key 和模型权限');
    }
  }

  void _send(String type, [Map<String, Object?> fields = const {}]) {
    if (_cancelled || _failed) return;
    final socket = _socket;
    if (socket == null) throw const AudioStreamFailure('实时语音连接尚未就绪');
    if (_outgoing.length >= 40) {
      throw const AudioStreamFailure('网络传输跟不上播放速度，请重新开始');
    }
    _outgoing.add(
      jsonEncode({'type': type, 'event_id': 'echo_${++_event}', ...fields}),
    );
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_sending || _cancelled || _failed) return;
    _sending = true;
    try {
      while (_outgoing.isNotEmpty && !_cancelled && !_failed) {
        await _socket!
            .addStream(Stream.value(_outgoing.removeFirst()))
            .timeout(const Duration(seconds: 3));
      }
    } catch (_) {
      _fail('实时语音发送失败，请检查网络后重新开始');
    } finally {
      _sending = false;
    }
  }

  void _receive(dynamic raw) {
    if (_cancelled || _failed) return;
    try {
      if (raw is! String || raw.length > 1024 * 1024) {
        throw const FormatException();
      }
      final event = jsonDecode(raw) as Map<String, dynamic>;
      if (event['type'] == 'error') {
        _fail('百炼实时语音请求失败，请检查 Key、模型权限和额度');
        return;
      }
      if (event['type'] == 'session.updated' && !_configured.isCompleted) {
        final modes = (event['session'] as Map?)?['modalities'];
        if (modes is! List || modes.length != 1 || modes.single != 'text') {
          _fail('实时语音未启用纯文字输出，请重新开始');
          return;
        }
        _configured.complete();
      }
      if (event['type'] == 'session.finished') {
        if (!_finished.isCompleted) _finished.complete();
        return;
      }
      for (final update in _decoder.accept(event)) {
        _controller.add(update);
      }
    } catch (e) {
      _fail(e is AudioStreamFailure ? e.message : '实时语音返回了无法读取的结果，请重新开始');
    }
  }

  void _fail(String message) {
    if (_cancelled || _failed) return;
    _failed = true;
    final failure = AudioStreamFailure(message);
    if (!_configured.isCompleted) _configured.completeError(failure);
    if (!_controller.isClosed) _controller.addError(failure);
    // Finish waits for this signal and must distinguish failure from clean EOF.
    if (!_finished.isCompleted) _finished.complete();
    unawaited(_socket?.close());
    _client.close(force: true);
  }

  @override
  void addPcm(Uint8List pcm) {
    if (_finishing || _cancelled || _failed || pcm.isEmpty) return;
    if (pcm.length > 16000 * 2 || pcm.length.isOdd) {
      throw const AudioStreamFailure('音频帧格式无效，请重新开始');
    }
    _send('input_audio_buffer.append', {'audio': base64Encode(pcm)});
  }

  @override
  Future<void> finish() async {
    if (_cancelled) return;
    _finishing = true;
    try {
      await ready;
      _send('session.finish');
      await _finished.future.timeout(const Duration(seconds: 10));
      if (_failed) throw const AudioStreamFailure('实时语音中断，最后一段可能未完成');
    } finally {
      await cancel();
    }
  }

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    _outgoing.clear();
    if (!_configured.isCompleted) _configured.complete();
    if (!_finished.isCompleted) _finished.complete();
    _client.close(force: true);
    await _socket?.close();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
