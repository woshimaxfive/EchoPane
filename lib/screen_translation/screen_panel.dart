import 'package:flutter/material.dart';

import '../ocr/model_store.dart';
import '../ocr/ocr_controller.dart';
import '../translation/translation_controller.dart';
import 'screen_controller.dart';

/// Controls the in-place pipeline without a separate screen-text viewer.
class ScreenTranslationPanel extends StatelessWidget {
  const ScreenTranslationPanel({
    super.key,
    required this.controller,
    this.translation,
    this.overlay,
  });
  final OcrController controller;
  final TranslationController? translation;
  final ScreenOverlayController? overlay;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      controller.models,
      translation,
      overlay,
    ]),
    builder: (context, _) {
      final models = controller.models;
      final downloading = models.phase == ModelPhase.downloading;
      final modelStatus = switch (models.phase) {
        ModelPhase.checking => '正在校验模型',
        ModelPhase.missing => '首次使用需要下载文字识别模型',
        ModelPhase.downloading =>
          '下载中 ${(models.received / models.total * 100).toStringAsFixed(0)}%',
        ModelPhase.failed => models.error ?? '模型不可用',
        ModelPhase.ready =>
          controller.loading
              ? '正在加载模型'
              : controller.ready
              ? '本地文字识别已就绪'
              : '文字识别未就绪',
      };
      final error =
          controller.error ??
          models.error ??
          translation?.settingsError ??
          translation?.error ??
          overlay?.error;
      final status =
          error ??
          (!controller.capture.running
              ? translation?.canTranslate == false
                    ? '请先配置翻译服务；点击开始后在画面原位置显示译文'
                    : '点击开始原位翻译，译文直接显示在画面上'
              : translation?.enabled == false
              ? '翻译已关闭，请停止后重新开始'
              : overlay?.enabled == false
              ? '原位译文已隐藏，可停止后重新开始'
              : overlay?.visible == true
              ? '正在显示原位译文'
              : translation?.phase == TranslationPhase.translating
              ? '正在翻译画面文字…'
              : '等待画面文字及对应译文…');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  modelStatus,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff708196),
                  ),
                ),
              ),
              if (downloading)
                TextButton(onPressed: models.cancel, child: const Text('取消')),
              if (models.phase == ModelPhase.missing ||
                  models.phase == ModelPhase.failed)
                TextButton(
                  onPressed: models.download,
                  child: const Text('下载模型 · 21.5 MB'),
                ),
              if (models.phase == ModelPhase.ready && controller.error != null)
                TextButton(
                  onPressed: controller.load,
                  child: const Text('重试识别'),
                ),
              if (translation?.error != null && translation!.enabled)
                TextButton(
                  onPressed: translation!.retry,
                  child: const Text('重试翻译'),
                ),
            ],
          ),
          if (downloading)
            LinearProgressIndicator(value: models.received / models.total),
          Text(
            status,
            key: const Key('screen-translation-status'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: error != null
                  ? Theme.of(context).colorScheme.error
                  : const Color(0xff708196),
            ),
          ),
          const SizedBox(height: 8),
        ],
      );
    },
  );
}
