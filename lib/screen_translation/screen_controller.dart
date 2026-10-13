import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../ocr/ocr_controller.dart';
import '../capture/capture_platform.dart';
import '../subtitles/caption_source.dart';
import '../translation/translation_controller.dart';
import 'screen_platform.dart';
import 'screen_renderer.dart';
import 'screen_settings.dart';

class ScreenOverlayController extends ChangeNotifier {
  ScreenOverlayController(
    this.ocr,
    this.captions,
    this.translation,
    this.platform,
    this.store,
  ) {
    ocr.addListener(_changed);
    captions.addListener(_changed);
    translation.addListener(_changed);
    platform.listen((_) {
      if (!_disposed) setEnabled(false);
    });
  }
  final OcrController ocr;
  final CaptionRouter captions;
  final TranslationController translation;
  final ScreenOverlayPlatform platform;
  final ScreenOverlaySettingsStore store;
  ScreenOverlaySettings settings = const ScreenOverlaySettings();
  bool initialized = false, enabled = false, visible = false, saving = false;
  String? error;
  String? notice;
  bool _disposed = false, _drawing = false, _queued = false;
  int _generation = 0;
  String _signature = '', _placement = '';

  Future<void> initialize() async {
    try {
      settings = await store.read();
    } catch (_) {
      error = '无法读取原位翻译设置，已使用默认设置';
    }
    if (_disposed) return;
    initialized = true;
    notifyListeners();
  }

  void setEnabled(bool value) {
    if (_disposed) return;
    enabled = value;
    error = null;
    _changed(force: true);
    notifyListeners();
  }

  Future<void> save(ScreenOverlaySettings next) async {
    next.validate();
    if (saving || _disposed) return;
    saving = true;
    notifyListeners();
    try {
      await store.write(next);
      if (_disposed) return;
      settings = next;
      error = null;
      _placement = '';
      _changed(force: true);
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  String _textKey(Iterable<String> text) => jsonEncode(
    text.map((line) => line.trim().replaceAll(RegExp(r'\s+'), ' ')).toList(),
  );
  bool get _eligible =>
      enabled &&
      captions.mode == RecognitionMode.screen &&
      ocr.capture.running &&
      ocr.error == null &&
      translation.enabled &&
      translation.translations.isNotEmpty &&
      _textKey(ocr.spatialLines.map((line) => line.text)) ==
          _textKey(translation.originals) &&
      ocr.spatialLines.length == translation.translations.length &&
      ocr.imageWidth > 0 &&
      ocr.imageHeight > 0 &&
      (ocr.capture.targetWindow == null || ocr.capture.outputRegion != null);

  void _changed({bool force = false}) {
    if (_disposed) return;
    final signature = jsonEncode([
      enabled,
      captions.mode.name,
      ocr.captionSession,
      ocr.capture.running,
      ocr.error,
      ocr.imageWidth,
      ocr.imageHeight,
      settings.mode == ScreenTranslationMode.replace ? ocr.revision : 0,
      ocr.capture.outputDisplay?.id,
      ocr.capture.outputRegion?.toMap(),
      ocr.capture.snapshot?.sessionExclusion,
      for (final line in ocr.spatialLines)
        [
          line.text,
          line.bounds.left.round(),
          line.bounds.top.round(),
          line.bounds.width.round(),
          line.bounds.height.round(),
          line.lineHeight.round(),
          line.background & 0xfff8f8f8,
        ],
      translation.enabled,
      translation.originals,
      translation.translations,
      settings.toJson(),
    ]);
    if (!force && signature == _signature) return;
    _signature = signature;
    ++_generation;
    _queued = true;
    unawaited(_draw());
  }

  Future<void> _hide() async {
    if (!visible) return;
    await platform.configure(
      visible: false,
      allowCapture: settings.allowCapture,
      displayId: ocr.capture.outputDisplay?.id ?? 0,
    );
    visible = false;
    _placement = '';
    if (!_disposed) notifyListeners();
  }

  Future<void> _draw() async {
    if (_drawing || _disposed) return;
    _drawing = true;
    try {
      while (_queued && !_disposed) {
        _queued = false;
        final token = _generation;
        if (!_eligible) {
          notice = null;
          await _hide();
          continue;
        }
        final display = ocr.capture.outputDisplay!;
        final origin =
            ocr.capture.outputRegion ??
            CaptureRegion(0, 0, ocr.imageWidth, ocr.imageHeight);
        final width = ocr.imageWidth;
        // The OCR crop stays fixed. Below-mode text can use space beyond it.
        final height = settings.mode == ScreenTranslationMode.below
            ? display.height - origin.y
            : ocr.imageHeight;
        if (width > 8192 || height > 8192 || width * height > 33554432) {
          await _hide();
          throw StateError('原位翻译范围过大，请缩小识别区域');
        }
        final blocks = layoutScreenTranslations(
          size: ui.Size(width.toDouble(), height.toDouble()),
          lines: ocr.spatialLines,
          translations: translation.translations,
          mode: settings.mode,
          fontScale: settings.fontScale,
          belowMinimum:
              ocr.capture.region != null &&
                  ocr.spatialLines.length == 1 &&
                  ocr.imageHeight - ocr.spatialLines.single.bounds.bottom <=
                      ocr.spatialLines.single.lineHeight
              ? ocr.imageHeight + 2.0
              : 0,
        );
        final missing =
            translation.translations
                .where((text) => text.trim().isNotEmpty)
                .length -
            blocks.length;
        notice = missing > 0
            ? '有 $missing 处译文下方空间不足，请调整识别区域或使用替换模式'
            : ocr.capture.targetWindow == null &&
                  settings.allowCapture &&
                  ocr.capture.snapshot?.sessionExclusion == false
            ? '当前系统使用兼容取样，译文可能闪烁；可关闭远程显示或选择跟随窗口'
            : null;
        if (blocks.isEmpty) {
          await _hide();
          if (!_disposed) notifyListeners();
          continue;
        }
        final union = blocks
            .map((block) => block.bounds)
            .reduce((a, b) => a.expandToInclude(b));
        final frameLeft = union.left.floor(), frameTop = union.top.floor();
        final frameWidth = union.right.ceil() - frameLeft,
            frameHeight = union.bottom.ceil() - frameTop;
        final frameRegion = CaptureRegion(
          origin.x + frameLeft,
          origin.y + frameTop,
          frameWidth,
          frameHeight,
        );
        final image = await renderScreenTranslations(
          width: frameWidth,
          height: frameHeight,
          blocks: [
            for (final block in blocks)
              PositionedTranslation(
                block.text,
                block.bounds.shift(
                  ui.Offset(-frameLeft.toDouble(), -frameTop.toDouble()),
                ),
                block.fontSize,
                block.background,
                backdrop: block.backdrop,
                paintBackground: block.paintBackground,
              ),
          ],
        );
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (_disposed || token != _generation || !_eligible || data == null) {
            continue;
          }
          final placement = jsonEncode([
            display.id,
            frameRegion.toMap(),
            settings.allowCapture,
          ]);
          if (!visible || _placement != placement) {
            final state = await platform.configure(
              visible: true,
              allowCapture: settings.allowCapture,
              displayId: display.id,
              region: frameRegion,
            );
            visible = state.visible;
            _placement = placement;
            if (state.width != frameWidth || state.height != frameHeight) {
              await _hide();
              throw StateError('画面尺寸已改变，请重新选择识别区域');
            }
          }
          if (_disposed || token != _generation || !_eligible) {
            await _hide();
            continue;
          }
          if (!await platform.present(
            frameWidth,
            frameHeight,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          )) {
            await _hide();
            throw StateError('原位翻译画面未显示，请重新开始');
          }
          error = null;
          if (!_disposed) notifyListeners();
        } finally {
          image.dispose();
        }
      }
    } catch (failure) {
      try {
        await _hide();
      } catch (_) {}
      if (!_disposed) {
        error = failure is StateError
            ? failure.message.toString()
            : '原位翻译暂不可用，请重新选择范围';
        notifyListeners();
      }
    } finally {
      _drawing = false;
      if (_queued && !_disposed) unawaited(_draw());
    }
  }

  Future<void> close() async {
    setEnabled(false);
    await _hide();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    unawaited(_hide().catchError((_) {}));
    platform.listen(null);
    ocr.removeListener(_changed);
    captions.removeListener(_changed);
    translation.removeListener(_changed);
    super.dispose();
  }
}
