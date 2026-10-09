import 'package:flutter/material.dart';

import 'screen_controller.dart';
import 'screen_renderer.dart';
import 'screen_settings.dart';

Future<void> showScreenOverlaySettings(
  BuildContext context,
  ScreenOverlayController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _ScreenOverlayDialog(controller: controller),
);

class _ScreenOverlayDialog extends StatefulWidget {
  const _ScreenOverlayDialog({required this.controller});
  final ScreenOverlayController controller;
  @override
  State<_ScreenOverlayDialog> createState() => _ScreenOverlayDialogState();
}

class _ScreenOverlayDialogState extends State<_ScreenOverlayDialog> {
  late ScreenOverlaySettings settings = widget.controller.settings;
  String? error;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return AlertDialog(
        title: const Text('画面原位翻译'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  key: const Key('screen-overlay-visible'),
                  title: const Text('显示原位译文'),
                  subtitle: const Text('开启屏幕识别和翻译后，译文跟随对应文字位置'),
                  value: controller.enabled,
                  onChanged: controller.initialized
                      ? controller.setEnabled
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ScreenTranslationMode>(
                  key: const Key('screen-overlay-mode'),
                  initialValue: settings.mode,
                  decoration: const InputDecoration(
                    labelText: '显示方式',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: ScreenTranslationMode.below,
                      child: Text('译文显示在原文下方'),
                    ),
                    DropdownMenuItem(
                      value: ScreenTranslationMode.replace,
                      child: Text('原位置替换原文'),
                    ),
                  ],
                  onChanged: controller.saving
                      ? null
                      : (mode) => setState(
                          () => settings = settings.copyWith(mode: mode),
                        ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('字号比例'),
                    Expanded(
                      child: Slider(
                        value: settings.fontScale,
                        min: 0.7,
                        max: 1.5,
                        divisions: 8,
                        onChanged: controller.saving
                            ? null
                            : (value) => setState(
                                () => settings = settings.copyWith(
                                  fontScale: value,
                                ),
                              ),
                      ),
                    ),
                    Text('${(settings.fontScale * 100).round()}%'),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  key: const Key('screen-overlay-remote'),
                  title: const Text('允许远程桌面和录屏显示译文'),
                  subtitle: const Text(
                    '识别取样时会短暂隐藏译文，部分画面可能闪烁。关闭后可减少闪烁，但远程软件可能看不到译文。',
                  ),
                  value: settings.allowCapture,
                  onChanged: controller.saving
                      ? null
                      : (value) => setState(
                          () =>
                              settings = settings.copyWith(allowCapture: value),
                        ),
                ),
                const SizedBox(height: 12),
                const Text('译文窗口允许鼠标穿透。可从这里关闭；Ctrl + Alt + T 也可隐藏（快捷键可用时）。'),
                const SizedBox(height: 10),
                const Text(
                  '当前替换使用采样背景色，复杂背景会留下色块。下方模式空间不足时会跳过该块，避免盖住其他原文。',
                  style: TextStyle(fontSize: 12, color: Color(0xff708196)),
                ),
                if (controller.enabled && !controller.visible)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('等待对应译文和可用位置…'),
                  ),
                if (error != null || controller.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      error ?? controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: controller.saving ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            key: const Key('screen-overlay-save'),
            onPressed: controller.saving
                ? null
                : () async {
                    try {
                      await controller.save(settings);
                      if (context.mounted) Navigator.pop(context);
                    } catch (_) {
                      if (mounted) setState(() => error = '无法保存原位翻译设置，请重试');
                    }
                  },
            child: Text(controller.saving ? '正在保存…' : '保存'),
          ),
        ],
      );
    },
  );
}
