import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model_store.dart';
import 'ocr_controller.dart';

class OcrPanel extends StatelessWidget {
  const OcrPanel({super.key, required this.controller});
  final OcrController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.models]),
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
                  ? (controller.capture.running ? '本地识别中' : '本地模型已就绪')
                  : '文字识别未就绪'),
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '识别原文',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
              IconButton(
                tooltip: '复制原文',
                icon: const Icon(Icons.copy_outlined, size: 17),
                onPressed: controller.text.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: controller.text),
                      ),
              ),
            ],
          ),
          if (downloading)
            LinearProgressIndicator(value: models.received / models.total),
          const SizedBox(height: 3),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
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
