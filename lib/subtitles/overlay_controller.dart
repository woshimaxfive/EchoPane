import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'caption_source.dart';
import '../translation/translation_controller.dart';
import 'overlay_platform.dart';
import 'overlay_renderer.dart';
import 'overlay_settings.dart';
import 'audio_presentation.dart';

class OverlayController extends ChangeNotifier {
  OverlayController(this.source, this.translation, this.platform, this.store) {
    source.addListener(_changed);
    translation.addListener(_changed);
    platform.listen(_windowChanged);
  }
  final CaptionSource source;
  final TranslationController translation;
  final OverlayPlatform platform;
  final OverlaySettingsStore store;
  OverlaySettings settings = const OverlaySettings();
  OverlayWindowState window = const OverlayWindowState();
  bool initialized = false;
  bool busy = false;
  String? error;
  bool _disposed = false;
  bool _drawing = false;
  bool _queued = false;
  int _generation = 0;
  String _signature = '';
  final _audioPresentation = AudioSubtitlePresentation();
  final _clock = Stopwatch()..start();
  Timer? _readingTimer;
  String _audioSession = '';
  List<SubtitleRow> _audioRows = [];
  List<SubtitleRow> get displayRows => source.captionTurns == null
      ? subtitleRows(settings, originals, translations)
      : List.unmodifiable(_audioRows);
  List<String> get originals =>
      source.captionRunning ? source.captionLines : [];
  List<String> get translations =>
      source.captionRunning &&
          translation.enabled &&
          listEquals(translation.originals, originals)
      ? translation.translations
      : [];
  String get status => !source.captionRunning
      ? '开始识别后，字幕会显示在这里'
      : source.captionError != null
      ? '识别暂不可用，请在主窗口检查'
      : settings.mode == SubtitleMode.translated &&
            translations.isEmpty &&
            originals.isNotEmpty
      ? translation.error != null
            ? '翻译失败，请在主窗口重试'
            : translation.enabled
            ? '正在等待译文…'
            : '请在主窗口开启翻译，或切换为原文'
      : source.waitingCaption;

  Future<void> initialize() async {
    try {
      settings = await store.read();
    } catch (_) {
      error = '无法读取字幕样式，已使用默认设置';
    }
    if (_disposed) return;
    initialized = true;
    notifyListeners();
  }

  Future<void> show(bool visible, {bool restore = false, bool? locked}) async {
    if (_disposed || busy) return;
    busy = true;
    error = null;
    notifyListeners();
    ++_generation;
    try {
      final next = await platform.configure(
        visible: visible,
        locked: visible && !restore && (locked ?? window.locked),
        restore: restore || (visible && !window.visible),
        displayId: source.captionDisplayId,
        allowCapture: settings.allowCapture,
      );
      if (_disposed) return;
      _windowChanged(next);
    } catch (_) {
      if (!_disposed) error = '无法更新悬浮字幕，请重试';
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> save(OverlaySettings next) async {
    next.validate();
    if (_disposed || busy) throw StateError('字幕窗口正忙，请稍后重试');
    busy = true;
    notifyListeners();
    final previous = settings;
    try {
      if (window.visible && next.allowCapture != previous.allowCapture) {
        final state = await platform.configure(
          visible: true,
          locked: window.locked,
          allowCapture: next.allowCapture,
          displayId: source.captionDisplayId,
        );
        _windowChanged(state);
      }
      await store.write(next);
      if (_disposed) return;
      settings = next;
      error = null;
      _changed(force: true);
      notifyListeners();
    } catch (_) {
      if (window.visible && next.allowCapture != previous.allowCapture) {
        try {
          final state = await platform.configure(
            visible: true,
            locked: window.locked,
            allowCapture: previous.allowCapture,
            displayId: source.captionDisplayId,
          );
          _windowChanged(state);
        } catch (_) {
          error = '无法恢复字幕捕获设置，请关闭字幕窗口后重试';
        }
      }
      rethrow;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _windowChanged(OverlayWindowState next) {
    if (_disposed) return;
    window = next;
    _changed(force: true);
    notifyListeners();
  }

  void _changed({bool force = false}) {
    if (_disposed) return;
    final turns = source.captionTurns;
    final audioActive =
        turns != null &&
        window.visible &&
        source.captionRunning &&
        source.captionError == null;
    final audioSession =
        '${source.captionSession}:${settings.mode.name}:${translation.enabled}';
    if (!audioActive || audioSession != _audioSession) {
      _audioPresentation.reset();
      _audioRows = [];
      _audioSession = audioSession;
    }
    if (audioActive) {
      _audioPresentation.update([
        for (final turn in turns)
          CaptionTurn(
            turn.id,
            turn.original,
            !translation.enabled
                ? ''
                : source.captionTranslations != null
                ? turn.translation
                : listEquals(translation.originals, source.captionLines)
                ? translations.join('\n')
                : '',
            turn.isFinal,
          ),
      ], _clock.elapsed);
      final scale = (window.dpi / 96).clamp(0.5, 4);
      _audioRows = _audioPresentation.layout(
        width: window.width / scale,
        height: window.height / scale,
        settings: settings,
        locked: window.locked,
        now: _clock.elapsed,
      );
      _readingTimer ??= Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _changed(),
      );
    } else {
      _readingTimer?.cancel();
      _readingTimer = null;
    }
    final signature = jsonEncode([
      displayRows.map((row) => [row.text, row.secondary]).toList(),
      status,
      settings.toJson(),
      window.visible,
      window.locked,
      window.width,
      window.height,
      window.dpi,
    ]);
    if (!force && signature == _signature) return;
    _signature = signature;
    ++_generation;
    if (window.visible) {
      _queued = true;
      unawaited(_draw());
    }
  }

  Future<void> _draw() async {
    if (_drawing || _disposed) return;
    _drawing = true;
    try {
      while (_queued && !_disposed && window.visible) {
        _queued = false;
        final token = _generation;
        if (window.width < 1 ||
            window.height < 1 ||
            window.width > 2400 ||
            window.height > 1200) {
          continue;
        }
        final width = window.width, height = window.height;
        final image = await renderSubtitles(
          width: width,
          height: height,
          scale: (window.dpi / 96).clamp(0.5, 4),
          settings: settings,
          rows: displayRows,
          locked: window.locked,
          status: status,
          prewrapped: source.captionTurns != null,
        );
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (data != null &&
              !_disposed &&
              token == _generation &&
              window.visible) {
            await platform.present(
              width,
              height,
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            );
          }
        } finally {
          image.dispose();
        }
      }
    } catch (_) {
      if (!_disposed) {
        error = '无法绘制悬浮字幕，请恢复字幕窗口后重试';
        notifyListeners();
      }
    } finally {
      _drawing = false;
    }
  }

  Future<void> close() => show(false);
  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _readingTimer?.cancel();
    _audioPresentation.reset();
    platform.listen(null);
    source.removeListener(_changed);
    translation.removeListener(_changed);
    super.dispose();
  }
}
