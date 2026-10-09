import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ocr/model_store.dart';
import '../subtitles/caption_text.dart';
import '../translation/settings_dialog.dart';
import '../translation/translation_controller.dart';
import 'audio_controller.dart';

class AudioPanel extends StatelessWidget {
  const AudioPanel({super.key, required this.controller, this.translation});
  final AudioController controller;
  final TranslationController? translation;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, controller.models, translation]),
    builder: (context, _) {
      final models = controller.models;
      final downloading = models.phase == ModelPhase.downloading;
      final status =
          controller.error ??
          (controller.isCloud
              ? controller.stopping
                    ? '正在完成最后一段…'
                    : controller.starting
                    ? '正在连接百炼实时语音…'
                    : controller.running
                    ? '正在实时翻译播放设备中的语音'
                    : '使用已保存的百炼北京 Key，目标语言沿用翻译设置'
              : switch (models.phase) {
                  ModelPhase.checking => '正在校验本地模型',
                  ModelPhase.missing => '首次使用需要下载语音模型',
                  ModelPhase.failed => models.error ?? '模型不可用，请重试',
                  ModelPhase.downloading =>
                    '下载中 ${(models.received / models.total * 100).toStringAsFixed(0)}%',
                  ModelPhase.ready =>
                    controller.starting
                        ? '正在加载本地识别'
                        : controller.recognizing
                        ? '正在识别语音'
                        : controller.running
                        ? '正在监听播放设备'
                        : '本地模型已就绪',
                });
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 210,
                child: DropdownButton<AudioBackend>(
                  key: const Key('audio-backend'),
                  isExpanded: true,
                  value: controller.backend,
                  items: const [
                    DropdownMenuItem(
                      value: AudioBackend.local,
                      child: Text('本地语音识别'),
                    ),
                    DropdownMenuItem(
                      value: AudioBackend.cloud,
                      child: Text('百炼实时翻译 · 云端'),
                    ),
                  ],
                  onChanged: controller.busy
                      ? null
                      : (value) {
                          if (value != null) controller.selectBackend(value);
                        },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.isCloud
                      ? '点击开始后将上传播放设备声音，按服务用量计费；只显示文字'
                      : '语音识别在本机运行，不上传声音',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff708196),
                  ),
                ),
              ),
            ],
          ),
          const Text(
            '听取电脑正在播放的语音，自动生成字幕。麦克风关闭。',
            style: TextStyle(color: Color(0xff708196)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  key: const Key('audio-device'),
                  isExpanded: true,
                  value: controller.deviceId,
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('跟随系统默认播放设备'),
                    ),
                    if (controller.deviceId.isNotEmpty &&
                        !controller.devices.any(
                          (d) => d.id == controller.deviceId,
                        ))
                      DropdownMenuItem(
                        value: controller.deviceId,
                        child: const Text('所选设备不可用，请重新选择'),
                      ),
                    for (final device in controller.devices)
                      DropdownMenuItem(
                        value: device.id,
                        child: Text(
                          device.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: controller.busy
                      ? null
                      : (value) {
                          if (value != null) controller.selectDevice(value);
                        },
                ),
              ),
              IconButton(
                tooltip: '刷新播放设备',
                onPressed: controller.busy ? null : controller.refresh,
                icon: const Icon(Icons.refresh, size: 19),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 130,
                child: DropdownButton<String>(
                  key: const Key('audio-language'),
                  isExpanded: true,
                  value: controller.language,
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('自动识别语言')),
                    DropdownMenuItem(value: 'en', child: Text('英语')),
                    DropdownMenuItem(value: 'ja', child: Text('日语')),
                  ],
                  onChanged: controller.busy
                      ? null
                      : (value) {
                          if (value != null) controller.selectLanguage(value);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.graphic_eq, color: Color(0xff167c80), size: 22),
              const SizedBox(width: 10),
              SizedBox(
                width: 80,
                child: LinearProgressIndicator(
                  value: controller.level,
                  minHeight: 5,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 12),
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
              if (downloading && !controller.isCloud)
                TextButton(onPressed: models.cancel, child: const Text('取消')),
              if (!controller.isCloud &&
                  (models.phase == ModelPhase.missing ||
                      models.phase == ModelPhase.failed))
                TextButton(
                  onPressed: models.download,
                  child: const Text('下载模型 · 148.8 MB'),
                ),
            ],
          ),
          if (downloading && !controller.isCloud)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(
                value: models.received / models.total,
              ),
            ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xffdae2e7)),
          Row(
            children: [
              Text(
                translation?.enabled == true ? '双语字幕' : '识别原文',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const Spacer(),
              if (translation != null) ...[
                const Text('翻译', style: TextStyle(fontSize: 12)),
                Switch(
                  key: const Key('audio-translation-toggle'),
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
                onPressed: controller.text.isEmpty
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: controller.text),
                      ),
                icon: const Icon(Icons.copy_outlined, size: 17),
              ),
            ],
          ),
          if (translation != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    translation!.error ??
                        (controller.isCloud
                            ? controller.provisional
                                  ? '临时字幕正在修正，完成后才加入记录'
                                  : '实时译文由百炼返回，目标语言在翻译设置中选择'
                            : translation!.enabled
                            ? translation!.phase == TranslationPhase.translating
                                  ? '正在翻译…'
                                  : '语音文字会发送到 ${translation!.settings.endpoint.host}'
                            : '原文识别可独立使用，配置翻译服务后可显示双语'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff708196),
                    ),
                  ),
                ),
                if (translation!.error != null)
                  TextButton(
                    onPressed: translation!.retry,
                    child: const Text('重试翻译'),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Expanded(
            child: CaptionText(
              originals: controller.lines,
              placeholder: controller.running
                  ? '等待播放设备中的语音…'
                  : '选择播放设备后点击开始，视频或会议中的语音会显示在这里。',
              translation: translation,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  controller.dropped > 0
                      ? '识别跟不上播放速度，已跳过部分音频'
                      : controller.isCloud
                      ? '自动识别语言${controller.detectedLanguage.isEmpty ? '' : '：${controller.detectedLanguage}'} · 不保存音频'
                      : controller.durationMs > 0
                      ? '检测语言：${controller.detectedLanguage} · 最近识别 ${controller.durationMs} ms'
                      : '本地语音识别 · 不保存音频',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff708196),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: const Key('audio-toggle'),
                onPressed:
                    controller.stopping ||
                        (!controller.isCloud &&
                            models.phase != ModelPhase.ready)
                    ? null
                    : controller.running || controller.starting
                    ? controller.stop
                    : controller.start,
                icon: Icon(
                  controller.running || controller.starting
                      ? Icons.stop
                      : Icons.play_arrow,
                  size: 19,
                ),
                label: Text(
                  controller.starting
                      ? '取消启动'
                      : controller.running
                      ? '停止'
                      : '开始',
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}
