import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../subtitles/caption_source.dart';
import 'provider.dart';
import 'settings.dart';

enum TranslationPhase { off, waiting, translating, ready, failed }

class TranslationController extends ChangeNotifier {
  TranslationController(
    this.source,
    this.provider,
    this.store,
    this.credentials, {
    this.debounce = const Duration(milliseconds: 350),
  }) {
    source.addListener(_sourceChanged);
  }
  final CaptionSource source;
  final TranslationProvider provider;
  final SettingsStore store;
  final CredentialStore credentials;
  final Duration debounce;
  TranslationSettings settings = const TranslationSettings();
  TranslationPhase phase = TranslationPhase.off;
  bool initialized = false;
  bool enabled = false;
  bool saving = false;
  String? settingsError;
  String? error;
  List<String> originals = [];
  List<String> translations = [];
  int durationMs = 0;
  String _key = '';
  int _generation = 0;
  String _signature = '';
  String _session = '';
  bool _disposed = false;
  bool _queued = false;
  Timer? _timer;
  TranslationRequest? _active;
  TranslationRequest? _test;
  final _cache = <String, List<String>>{};
  bool get hasKey => _key.isNotEmpty;
  bool get canTranslate =>
      initialized &&
      settingsError == null &&
      (hasKey ||
          {'localhost', '127.0.0.1', '::1'}.contains(settings.endpoint.host));

  Future<void> initialize() async {
    try {
      settings = await store.read();
      _key = await credentials.read() ?? '';
      settingsError = null;
    } catch (_) {
      settingsError = '无法读取翻译配置，请打开翻译服务设置重新保存';
    }
    if (_disposed) return;
    initialized = true;
    _sourceChanged();
    _notify();
  }

  Future<void> configure(TranslationSettings next, {String? newKey}) async {
    if (saving) return;
    next.validate();
    final cleanKey = newKey?.trim();
    if (cleanKey != null &&
        (cleanKey.length > 2048 ||
            cleanKey.contains(RegExp(r'[^\x21-\x7e]')))) {
      throw const FormatException('API Key 格式无效');
    }
    final previous = settings;
    final sameOrigin = next.endpoint.origin == previous.endpoint.origin;
    final nextKey = cleanKey ?? (sameOrigin ? _key : '');
    setEnabled(false);
    saving = true;
    _notify();
    try {
      await store.write(next);
      try {
        if (nextKey.isEmpty) {
          await credentials.delete();
        } else {
          await credentials.write(nextKey);
        }
      } catch (_) {
        await store.write(previous);
        rethrow;
      }
      settings = next;
      _key = nextKey;
      _cache.clear();
      settingsError = null;
      initialized = true;
    } catch (_) {
      throw const TranslationFailure('保存失败，请检查本机存储权限和 Windows 凭据服务');
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> removeKey() async {
    setEnabled(false);
    await credentials.delete();
    _key = '';
    _cache.clear();
    _notify();
  }

  Future<String> testConnection(
    TranslationSettings next,
    String? newKey,
  ) async {
    next.validate();
    _test?.cancel();
    final key =
        newKey?.trim() ??
        (next.endpoint.origin == settings.endpoint.origin ? _key : '');
    if (key.isEmpty &&
        !{'localhost', '127.0.0.1', '::1'}.contains(next.endpoint.host)) {
      throw const TranslationFailure('请先填写 API Key');
    }
    final request = provider.translate(next, key, ['Hello, world.']);
    _test = request;
    try {
      return (await request.result).single;
    } finally {
      if (identical(_test, request)) _test = null;
    }
  }

  void cancelTest() {
    _test?.cancel();
    _test = null;
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    _invalidate();
    enabled = value && canTranslate;
    phase = enabled ? TranslationPhase.waiting : TranslationPhase.off;
    originals = source.captionRunning ? source.captionLines : [];
    _signature = _fingerprint(originals);
    if (enabled) _schedule();
    _notify();
  }

  String _fingerprint(List<String> values) => jsonEncode(
    values.map((line) => line.trim().replaceAll(RegExp(r'\s+'), ' ')).toList(),
  );

  void _sourceChanged() {
    if (_disposed) return;
    final next = source.captionRunning ? source.captionLines : <String>[];
    final signature = _fingerprint(next);
    final session =
        '${source.captionSession}:${source.captionRunning}:${source.captionError}';
    if (signature == _signature && session == _session) return;
    if (session != _session) _cache.clear();
    _session = session;
    _invalidate();
    originals = next;
    _signature = signature;
    if (!source.captionRunning) _cache.clear();
    phase = enabled ? TranslationPhase.waiting : TranslationPhase.off;
    if (enabled && source.captionError == null) _schedule();
    _notify();
  }

  void _invalidate() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _queued = false;
    _active?.cancel();
    translations = [];
    durationMs = 0;
    error = null;
  }

  bool get _eligible =>
      !_disposed &&
      enabled &&
      source.captionRunning &&
      source.captionError == null &&
      originals.isNotEmpty;
  void _schedule() {
    if (!_eligible) return;
    final cached = _cache[_signature];
    if (cached != null) {
      translations = List.of(cached);
      phase = TranslationPhase.ready;
      return;
    }
    _timer = Timer(debounce, _begin);
  }

  Future<void> _begin() async {
    if (!_eligible) return;
    if (_active != null) {
      _queued = true;
      return;
    }
    final token = _generation;
    final signature = _signature;
    final clock = Stopwatch()..start();
    phase = TranslationPhase.translating;
    TranslationRequest? request;
    try {
      request = provider.translate(settings, _key, originals);
      _active = request;
      _notify();
      final output = await request.result;
      if (token == _generation && _eligible) {
        if (output.length != originals.length ||
            output.any((line) => line.trim().isEmpty)) {
          throw const TranslationFailure('译文段落不完整，请重试');
        }
        translations = List.of(output);
        _cache[signature] = List.of(output);
        if (_cache.length > 64) _cache.remove(_cache.keys.first);
        durationMs = clock.elapsedMilliseconds;
        phase = TranslationPhase.ready;
      }
    } catch (failure) {
      if (token == _generation && _eligible) {
        error = failure is TranslationFailure ? failure.message : '翻译失败，请手动重试';
        phase = TranslationPhase.failed;
      }
    } finally {
      if (identical(_active, request)) _active = null;
      if (!_disposed) {
        _notify();
        if (_queued && _eligible) {
          _queued = false;
          unawaited(_begin());
        }
      }
    }
  }

  void retry() {
    if (!_eligible) return;
    _invalidate();
    _cache.remove(_signature);
    phase = TranslationPhase.waiting;
    _schedule();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _invalidate();
    cancelTest();
    _key = '';
    _cache.clear();
    source.removeListener(_sourceChanged);
    super.dispose();
  }
}
