import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model_store.dart';
import 'ocr_controller.dart';
import '../translation/translation_controller.dart';
import '../translation/settings_dialog.dart';

class OcrPanel extends StatelessWidget {
  const OcrPanel({super.key, required this.controller, this.translation});
  final OcrController controller;
  final TranslationController? translation;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.models, translation]),
    builder: (context, _) {
      final models = controller.models;
      final downloading = models.phase == ModelPhase.downloading;
      final status = switch (models.phase) {
        ModelPhase.checking => '正在校验模型',
        ModelPhase.missing => '需要下载本地识别模型',
        ModelPhase.downloading =>
          '正在下载 ${(models.received / models.total * 100).toStringAsFixed(0)}%',
        ModelPhase.failed => models.error ?? '模型不可用',
        ModelPhase.ready =>
          controller.error ??
              (controller.loading
                  ? '正在加载模型'
                  : controller.ready
                  ? (controller.capture.running
                        ? controller.stabilizing
                              ? '正在稳定字幕'
                              : '本地识别中'
                        : '本地模型已就绪')
                  : '文字识别未就绪'),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                translation?.enabled == true ? '双语字幕' : '识别原文',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: controller.error != null || models.error != null
                        ? Theme.of(context).colorScheme.error
                        : const Color(0xff708196),
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
                TextButton(onPressed: controller.load, child: const Text('重试')),
              if (translation != null) ...[
                const Text('翻译', style: TextStyle(fontSize: 12)),
                Switch(
                  key: const Key('translation-toggle'),
                  value: translation!.enabled,
                  onChanged: translation!.initialized
                      ? (value) {
                          if (value && !translation!.canTranslate) {
                            showTranslationSettings(context, translation!);
                          } else {
                            translation!.setEnabled(value);
                          }
                        }
                      : null,
                ),
              ],
              IconButton(
                tooltip: '复制原文',
                icon: const Icon(Icons.copy_outlined, size: 17),
                onPressed: controller.text.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: controller.text),
                      ),
              ),
              if (translation?.enabled == true)
                IconButton(
                  tooltip: '复制双语',
                  icon: const Icon(Icons.copy_all_outlined, size: 17),
                  onPressed: translation!.translations.isEmpty
                      ? null
                      : () {
                          final value = [
                            for (
                              int i = 0;
                              i < translation!.originals.length;
                              i++
                            )
                              '${translation!.originals[i]}\n${translation!.translations[i]}',
                          ].join('\n\n');
                          Clipboard.setData(ClipboardData(text: value));
                        },
                ),
            ],
          ),
          if (downloading)
            LinearProgressIndicator(value: models.received / models.total),
          if (translation != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    translation!.settingsError ??
                        translation!.error ??
                        (translation!.enabled
                            ? switch (translation!.phase) {
                                TranslationPhase.off => '翻译已关闭',
                                TranslationPhase.waiting =>
                                  '等待稳定文字 · 发送到 ${translation!.settings.endpoint.host}',
                                TranslationPhase.translating =>
                                  '正在翻译 · ${translation!.settings.endpoint.host}',
                                TranslationPhase.ready =>
                                  '译文已更新 · ${translation!.settings.endpoint.host}',
                                TranslationPhase.failed => '翻译不可用',
                              }
                            : translation!.hasKey
                            ? '翻译已关闭，开启后仅发送识别文字'
                            : '可在翻译服务中配置 Key，原文识别可独立使用'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          translation!.error != null ||
                              translation!.settingsError != null
                          ? Theme.of(context).colorScheme.error
                          : const Color(0xff708196),
                    ),
                  ),
                ),
                if (translation!.error != null && translation!.enabled)
                  TextButton(
                    onPressed: translation!.retry,
                    child: const Text('重试翻译'),
                  ),
              ],
            ),
          const SizedBox(height: 3),
          Expanded(
            child: SingleChildScrollView(
              child:
                  translation?.enabled == true &&
                      translation!.translations.isNotEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < translation!.originals.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectableText(
                                  translation!.originals[i],
                                  key: Key('original-$i'),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.4,
                                    color: Color(0xff708196),
                                  ),
                                ),
                                SelectableText(
                                  translation!.translations[i],
                                  key: Key('translated-$i'),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    height: 1.5,
                                    color: Color(0xff243247),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    )
                  : SelectableText(
                      controller.text.isEmpty
                          ? controller.capture.running && controller.ready
                                ? '等待画面中的文字…'
                                : '框选字幕区域后点击开始，英语、日语文字会显示在这里。'
                          : controller.text,
                      key: const Key('ocr-text'),
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.5,
                        color: controller.text.isEmpty
                            ? const Color(0xff708196)
                            : const Color(0xff243247),
                      ),
                    ),
            ),
          ),
        ],
      );
    },
  );
}
