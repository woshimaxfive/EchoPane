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
  _Turn(this.id, this.sequence);
  final String id;
  final int sequence;
  String source = '', language = '', output = '';
  bool sourceFinal = false, retired = false, finalCounted = false;
  Duration lastSourceAt = Duration.zero;
}

class _Output {
  _Output(this.id, this.receivedAt);
  final String id;
  final Duration receivedAt;
  String source = '', response = '', text = '';
  bool textDone = false, skipped = false;
}

class _Response {
  String status = '';
  Duration endedAt = Duration.zero;
}

/// Vendor event IDs and conversation links stay inside this adapter.
class BailianAudioDecoder {
  static const _grace = Duration(seconds: 5);
  final _turns = <String, _Turn>{};
  final _outputs = <String, _Output>{};
  final _responses = <String, _Response>{};
  final _retired = <String>{};
  final _notices = <String>[];
  final _trace = <Map<String, Object?>>[];
  final _aliases = <String, int>{};
  int _sequence = 0, _alias = 0, _pairingFailures = 0;

  List<Map<String, Object?>> get diagnostics => [
    for (final row in _trace) Map.unmodifiable(row),
  ];
  List<String> takeNotices() {
    final result = List<String>.of(_notices);
    _notices.clear();
    return result;
  }

  int? _name(String id) {
    if (id.isEmpty) return null;
    final name = _aliases.putIfAbsent(id, () => ++_alias);
    while (_aliases.length > 512) {
      _aliases.remove(_aliases.keys.first);
    }
    return name;
  }

  void _record(
    String type,
    String item,
    Duration now, {
    String detail = '',
    int? audioOffsetMs,
  }) {
    final turn = _turns[item] ?? _turns[_outputs[item]?.source];
    _trace.add({
      'ms': now.inMilliseconds,
      'event': type,
      if (item.isNotEmpty) 'item': _name(item),
      if (turn case final known?) 'sourceTurn': known.sequence,
      if (detail.isNotEmpty) 'state': detail,
      'audioOffsetMs': ?audioOffsetMs,
    });
    if (_trace.length > 128) _trace.removeAt(0);
  }

  String _identifier(Object? value) {
    final id = value as String? ?? '';
    if (id.length > 256) throw const FormatException();
    return id;
  }

  _Turn _turn(String id) =>
      _turns.putIfAbsent(id, () => _Turn(id, ++_sequence));
  _Output _output(String id, Duration now) =>
      _outputs.putIfAbsent(id, () => _Output(id, now));

  SpeechUpdate _update(_Turn turn) {
    final output = _outputs[turn.output];
    final response = _responses[output?.response];
    final finalPair =
        !turn.retired &&
        turn.sourceFinal &&
        output?.textDone == true &&
        response?.status == 'completed' &&
        turn.source.trim().isNotEmpty &&
        output!.text.trim().isNotEmpty;
    if (finalPair && !turn.finalCounted) {
      turn.finalCounted = true;
      _pairingFailures = 0;
    }
    return SpeechUpdate(
      id: turn.id,
      source: turn.source,
      translation: turn.retired ? '' : output?.text ?? '',
      language: turn.language,
      sequence: turn.sequence,
      isFinal: finalPair,
    );
  }

  void _remember(String id) {
    if (id.isNotEmpty) _retired.add(id);
    while (_retired.length > 512) {
      _retired.remove(_retired.first);
    }
  }

  void _skip(String id, Duration now, {bool pairing = true}) {
    if (_retired.contains(id)) return;
    final output = _outputs[id];
    if (output != null) output.skipped = true;
    final turn = _turns[id] ?? _turns[output?.source];
    if (turn?.retired == true) return;
    if (turn != null) {
      turn.retired = true;
      _remember(turn.id);
      _remember(turn.output);
    }
    _remember(id);
    _record(
      'turn.skipped',
      id,
      now,
      detail: pairing ? 'unpaired' : 'incomplete',
    );
    _notices.add(pairing ? '有一段实时字幕未能配对，已跳过并继续监听' : '有一段实时翻译未完整完成，已保留原文并继续监听');
    if (pairing && ++_pairingFailures >= 3) {
      throw const AudioStreamFailure('连续多段实时字幕无法配对，请重新开始；可复制诊断信息');
    }
  }

  List<SpeechUpdate> accept(
    Map<String, dynamic> event, {
    Duration now = Duration.zero,
  }) {
    final type = event['type'] as String? ?? '';
    if (type.length > 128) throw const FormatException();
    final id = _identifier(event['item_id']);
    // Do not record transcript, audio, credentials or arbitrary provider errors.
    final audioOffset = switch (type) {
      'input_audio_buffer.speech_started' => event['audio_start_ms'],
      'input_audio_buffer.speech_stopped' => event['audio_end_ms'],
      _ => null,
    };
    _record(
      type,
      id,
      now,
      audioOffsetMs: audioOffset is int && audioOffset >= 0
          ? audioOffset
          : null,
    );
    final changed = <String>{};
    if (type == 'input_audio_buffer.speech_started') {
      if (id.isNotEmpty && !_retired.contains(id)) _turn(id);
    } else if (type == 'conversation.item.created') {
      final item = event['item'] as Map?;
      final itemId = _identifier(item?['id']);
      final content = item?['content'] as List? ?? [];
      if (itemId.isNotEmpty &&
          (!_retired.contains(itemId) || _outputs[itemId]?.skipped == true)) {
        final input =
            item?['role'] == 'user' ||
            content.any((c) => c is Map && c['type'] == 'input_audio');
        if (input) {
          _turn(itemId);
        } else {
          final previous = _identifier(event['previous_item_id']);
          if (_retired.contains(previous) && !_turns.containsKey(previous)) {
            _remember(itemId);
          } else if (previous.isNotEmpty) {
            final output = _output(itemId, now);
            if (output.source.isNotEmpty && output.source != previous) {
              throw const AudioStreamFailure('实时字幕的消息关联发生冲突，请重新开始');
            }
            final turn = _turn(previous);
            if (turn.output.isNotEmpty && turn.output != itemId) {
              throw const AudioStreamFailure('同一句语音收到冲突的翻译关联，请重新开始');
            }
            output.source = previous;
            turn.output = itemId;
            if (output.skipped) {
              turn.retired = true;
              _remember(turn.id);
            }
            changed.add(previous);
            _record(
              'turn.linked',
              itemId,
              now,
              detail: 'source=${_name(previous)}',
            );
          }
        }
      }
    } else if (type == 'conversation.item.input_audio_transcription.text' ||
        type == 'conversation.item.input_audio_transcription.completed') {
      if (id.isNotEmpty &&
          (!_retired.contains(id) ||
              (_turns[id]?.retired == true &&
                  _turns[id]?.sourceFinal == false))) {
        final turn = _turn(id);
        turn.lastSourceAt = now;
        if (type.endsWith('.completed')) {
          turn.source = event['transcript'] as String? ?? '';
          turn.sourceFinal = true;
        } else if (!turn.sourceFinal) {
          // Replace snapshots instead of appending provisional revisions.
          turn.source = '${event['text'] ?? ''}${event['stash'] ?? ''}';
        }
        turn.language = event['language'] as String? ?? turn.language;
        changed.add(id);
      }
    } else if (type == 'conversation.item.input_audio_transcription.failed') {
      if (id.isNotEmpty) {
        _skip(id, now);
        changed.add(id);
      }
    } else if (type == 'response.text.text' || type == 'response.text.done') {
      if (id.isNotEmpty && !_retired.contains(id)) {
        final output = _output(id, now);
        final response = _identifier(event['response_id']);
        if (output.response.isNotEmpty &&
            response.isNotEmpty &&
            output.response != response) {
          throw const AudioStreamFailure('实时译文的响应编号发生冲突，请重新开始');
        }
        if (response.isNotEmpty) output.response = response;
        if (type.endsWith('.done')) {
          output.text = event['text'] as String? ?? '';
          output.textDone = true;
        } else if (!output.textDone) {
          output.text = '${event['text'] ?? ''}${event['stash'] ?? ''}';
        }
        if (output.source.isNotEmpty) changed.add(output.source);
      }
    } else if (type == 'response.output_item.added' ||
        type == 'response.output_item.done') {
      final item = event['item'] as Map?;
      final itemId = _identifier(item?['id']);
      final response = _identifier(event['response_id']);
      if (itemId.isNotEmpty && !_retired.contains(itemId)) {
        final output = _output(itemId, now);
        if (output.response.isNotEmpty && output.response != response) {
          throw const AudioStreamFailure('实时译文的响应编号发生冲突，请重新开始');
        }
        if (response.isNotEmpty) output.response = response;
        if (output.source.isNotEmpty) changed.add(output.source);
      }
    } else if (type == 'response.done') {
      final response = event['response'] as Map?;
      final responseId = _identifier(response?['id']);
      if (responseId.isNotEmpty && !_retired.contains(responseId)) {
        final state = _responses.putIfAbsent(responseId, _Response.new);
        final status = response?['status'] as String? ?? '';
        if (!{
          'completed',
          'cancelled',
          'failed',
          'incomplete',
        }.contains(status)) {
          throw const AudioStreamFailure('实时翻译返回未知的完成状态，请重新开始');
        }
        _record('response.finished', responseId, now, detail: status);
        if (state.status.isNotEmpty && state.status != status) {
          throw const AudioStreamFailure('实时翻译的完成状态发生冲突，请重新开始');
        }
        if (state.status.isEmpty) {
          state.status = status;
          state.endedAt = now;
        }
        for (final item in response?['output'] as List? ?? []) {
          if (item is! Map || item['id'] is! String) continue;
          final itemId = _identifier(item['id']);
          if (_retired.contains(itemId)) continue;
          final output = _output(itemId, now);
          if (output.response.isNotEmpty && output.response != responseId) {
            throw const AudioStreamFailure('实时译文的响应编号发生冲突，请重新开始');
          }
          output.response = responseId;
        }
        for (final output in _outputs.values) {
          if (output.response == responseId && output.source.isNotEmpty) {
            changed.add(output.source);
          }
        }
      }
    }
    for (final turn in _turns.values) {
      if (turn.sourceFinal && turn.source.trim().isEmpty && !turn.retired) {
        turn.retired = true;
        _remember(turn.id);
        _remember(turn.output);
      }
    }
    for (final output in _outputs.values) {
      final status = _responses[output.response]?.status ?? '';
      if (status.isNotEmpty &&
          status != 'completed' &&
          !_retired.contains(output.id)) {
        _skip(output.id, now, pairing: false);
        if (output.source.isNotEmpty) changed.add(output.source);
      }
    }
    _trim();
    return [
      for (final id in changed)
        if (_turns.containsKey(id)) _update(_turns[id]!),
    ];
  }

  List<SpeechUpdate> expire(Duration now, {bool finished = false}) {
    final changed = <String>{};
    for (final turn in _turns.values) {
      if (!turn.retired &&
          turn.sourceFinal &&
          turn.output.isEmpty &&
          (finished || now - turn.lastSourceAt >= _grace)) {
        _skip(turn.id, now);
        changed.add(turn.id);
      }
    }
    for (final output in _outputs.values) {
      if (_retired.contains(output.id)) continue;
      final turn = _turns[output.source];
      final response = _responses[output.response];
      final missingLink = turn == null;
      final last =
          turn == null ||
              turn.lastSourceAt < (response?.endedAt ?? Duration.zero)
          ? response?.endedAt ?? output.receivedAt
          : turn.lastSourceAt;
      final incomplete =
          turn == null ||
          !turn.sourceFinal ||
          !output.textDone ||
          response?.status != 'completed' ||
          output.text.trim().isEmpty;
      if (incomplete &&
          (finished ||
              (missingLink
                  ? now - output.receivedAt >= _grace
                  : response?.status.isNotEmpty == true &&
                        now - last >= _grace))) {
        _skip(output.id, now);
        if (turn != null) changed.add(turn.id);
      }
    }
    _trim();
    return [
      for (final id in changed)
        if (_turns.containsKey(id)) _update(_turns[id]!),
    ];
  }

  void _trim() {
    while (_turns.length > 128) {
      final old = _turns.values
          .where((turn) => turn.retired || _update(turn).isFinal)
          .firstOrNull;
      if (old == null) throw const AudioStreamFailure('实时字幕待完成内容过多，请重新开始');
      _remember(old.id);
      _turns.remove(old.id);
      final output = _outputs.remove(old.output);
      _remember(old.output);
      if (output != null) {
        _responses.remove(output.response);
        _remember(output.response);
      }
    }
    while (_outputs.length > 256) {
      final old = _outputs.values
          .where((o) => _retired.contains(o.id))
          .firstOrNull;
      if (old == null) throw const AudioStreamFailure('实时字幕待关联内容过多，请重新开始');
      _outputs.remove(old.id);
    }
    while (_responses.length > 256) {
      final old = _responses.keys
          .where(
            (id) => !_outputs.values.any(
              (o) => o.response == id && !_retired.contains(o.id),
            ),
          )
          .firstOrNull;
      if (old == null) {
        throw const AudioStreamFailure('实时字幕待完成响应过多，请重新开始');
      }
      _responses.remove(old);
      _remember(old);
    }
    final characters =
        _turns.values.fold<int>(0, (n, t) => n + t.source.length) +
        _outputs.values.fold<int>(0, (n, o) => n + o.text.length);
    if (characters > 1000000) throw const AudioStreamFailure('实时字幕缓存过大，请重新开始');
  }

  void clear() {
    _turns.clear();
    _outputs.clear();
    _responses.clear();
    _retired.clear();
    _notices.clear();
  }
}

class BailianAudioSession
    implements AudioStreamSession, AudioStreamDiagnostics {
  BailianAudioSession(
    TranslationSettings settings,
    String key, {
    String source = 'auto',
    Future<WebSocket> Function(Uri, Map<String, String>)? connect,
  }) {
    _dial = connect;
    _ready = _connect(settings, key, source);
  }
  final _controller = StreamController<SpeechUpdate>();
  final _decoder = BailianAudioDecoder();
  final _clock = Stopwatch()..start();
  Timer? _pendingTimer;
  Future<WebSocket> Function(Uri, Map<String, String>)? _dial;
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
  @override
  List<Map<String, Object?>> get diagnostics => _decoder.diagnostics;

  Future<void> _connect(
    TranslationSettings settings,
    String key,
    String source,
  ) async {
    try {
      if (key.isEmpty) throw const AudioStreamFailure('请先在翻译设置中保存百炼 Key');
      final endpoint = bailianAudioEndpoint(settings);
      final target = bailianAudioTarget(settings.target);
      final headers = {'Authorization': 'Bearer $key'};
      _socket =
          await (_dial?.call(endpoint, headers) ??
                  WebSocket.connect(
                    endpoint.toString(),
                    headers: headers,
                    customClient: _client,
                  ))
              .timeout(const Duration(seconds: 20));
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
      if (!_cancelled && !_failed) {
        _pendingTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
          try {
            _publish(_decoder.expire(_clock.elapsed));
          } catch (e) {
            _fail(e is AudioStreamFailure ? e.message : '实时字幕状态异常，请重新开始');
          }
        });
      }
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
        _publish(_decoder.expire(_clock.elapsed, finished: true));
        if (!_finished.isCompleted) _finished.complete();
        return;
      }
      _publish(_decoder.accept(event, now: _clock.elapsed));
    } catch (e) {
      _fail(e is AudioStreamFailure ? e.message : '实时语音返回了无法读取的结果，请重新开始');
    }
  }

  void _publish(List<SpeechUpdate> updates) {
    for (final update in updates) {
      _controller.add(update);
    }
    for (final message in _decoder.takeNotices()) {
      _controller.addError(AudioStreamNotice(message));
    }
  }

  void _fail(String message) {
    if (_cancelled || _failed) return;
    _failed = true;
    _pendingTimer?.cancel();
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
    _pendingTimer?.cancel();
    _decoder.clear();
    _outgoing.clear();
    if (!_configured.isCompleted) _configured.complete();
    if (!_finished.isCompleted) _finished.complete();
    _client.close(force: true);
    await _socket?.close();
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
