import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../ocr/ocr_controller.dart';
import '../translation/translation_controller.dart';
import 'overlay_platform.dart';
import 'overlay_renderer.dart';
import 'overlay_settings.dart';

class OverlayController extends ChangeNotifier {
  OverlayController(this.ocr, this.translation, this.platform, this.store) {
    ocr.addListener(_changed);
    translation.addListener(_changed);
    platform.listen(_windowChanged);
  }
  final OcrController ocr;
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
  List<String> get originals =>
      ocr.capture.running ? ocr.lines.map((line) => line.text).toList() : [];
  List<String> get translations =>
      ocr.capture.running &&
          translation.enabled &&
          listEquals(translation.originals, originals)
      ? translation.translations
      : [];
  String get status => !ocr.capture.running
      ? '开始识别后，字幕会显示在这里'
      : ocr.error != null
      ? '文字识别暂不可用，请在主窗口检查'
      : settings.mode == SubtitleMode.translated &&
            translations.isEmpty &&
            originals.isNotEmpty
      ? translation.error != null
            ? '翻译失败，请在主窗口重试'
            : translation.enabled
            ? '正在等待译文…'
            : '请在主窗口开启翻译，或切换为原文'
      : '等待画面中的文字…';

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
        displayId: ocr.capture.display?.id,
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
    await store.write(next);
    if (_disposed) return;
    settings = next;
    error = null;
    _changed(force: true);
    notifyListeners();
  }

  void _windowChanged(OverlayWindowState next) {
    if (_disposed) return;
    window = next;
    _changed(force: true);
    notifyListeners();
  }

  void _changed({bool force = false}) {
    if (_disposed) return;
    final signature = jsonEncode([
      originals,
      translations,
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
          rows: subtitleRows(settings, originals, translations),
          locked: window.locked,
          status: status,
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
    platform.listen(null);
    ocr.removeListener(_changed);
    translation.removeListener(_changed);
    super.dispose();
  }
}
