import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'overlay_controller.dart';
import 'overlay_renderer.dart';
import 'overlay_settings.dart';

Future<void> showOverlaySettings(
  BuildContext context,
  OverlayController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => OverlaySettingsDialog(controller: controller),
);

class OverlaySettingsDialog extends StatefulWidget {
  const OverlaySettingsDialog({super.key, required this.controller});
  final OverlayController controller;
  @override
  State<OverlaySettingsDialog> createState() => _OverlaySettingsDialogState();
}

class _OverlaySettingsDialogState extends State<OverlaySettingsDialog> {
  late OverlaySettings _settings;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _settings = widget.controller.settings;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      return AlertDialog(
        title: const Text('悬浮字幕'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示字幕窗口'),
                  subtitle: const Text('置顶显示，主窗口最小化后继续运行'),
                  value: controller.window.visible,
                  key: const Key('overlay-visible'),
                  onChanged: controller.initialized && !controller.busy
                      ? (value) => controller.show(value)
                      : null,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<SubtitleMode>(
                  initialValue: _settings.mode,
                  key: const Key('overlay-mode'),
                  decoration: const InputDecoration(
                    labelText: '显示内容',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: SubtitleMode.bilingual,
                      child: Text('双语对照'),
                    ),
                    DropdownMenuItem(
                      value: SubtitleMode.translated,
                      child: Text('只看译文'),
                    ),
                    DropdownMenuItem(
                      value: SubtitleMode.original,
                      child: Text('只看原文'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (mode) => setState(
                          () => _settings = _settings.copyWith(mode: mode),
                        ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  key: const Key('overlay-allow-capture'),
                  title: const Text('允许远程桌面和录屏显示字幕'),
                  subtitle: const Text('保存后生效。开启时请将字幕移出屏幕识别区域，避免重复识别。'),
                  value: _settings.allowCapture,
                  onChanged: _saving || controller.busy
                      ? null
                      : (value) => setState(
                          () => _settings = _settings.copyWith(
                            allowCapture: value,
                          ),
                        ),
                ),
                _slider(
                  '字号',
                  '${_settings.fontSize.round()}',
                  _settings.fontSize,
                  16,
                  48,
                  32,
                  (value) => _settings = _settings.copyWith(fontSize: value),
                ),
                _slider(
                  '背景不透明度',
                  '${(_settings.backgroundOpacity * 100).round()}%',
                  _settings.backgroundOpacity,
                  0,
                  1,
                  20,
                  (value) =>
                      _settings = _settings.copyWith(backgroundOpacity: value),
                ),
                _slider(
                  '最多字幕行数',
                  '${_settings.maxLines}',
                  _settings.maxLines.toDouble(),
                  2,
                  10,
                  8,
                  (value) =>
                      _settings = _settings.copyWith(maxLines: value.round()),
                ),
                const Text(
                  '超出窗口或行数时保留末尾内容；双语优先成对显示。',
                  style: TextStyle(fontSize: 12, color: Color(0xff708196)),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 132,
                  width: double.infinity,
                  child: _SubtitlePreview(settings: _settings),
                ),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('鼠标穿透'),
                  subtitle: const Text('开启后可操作下方视频；从主窗口或托盘“恢复字幕操作”退出'),
                  key: const Key('overlay-locked'),
                  value: controller.window.locked,
                  onChanged: controller.window.visible && !controller.busy
                      ? (value) => controller.show(true, locked: value)
                      : null,
                ),
                if (controller.window.visible)
                  Text(
                    controller.window.hotkey
                        ? '快捷恢复：Ctrl + Alt + S'
                        : '快捷键未注册，可使用主窗口或托盘恢复操作。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff708196),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('overlay-restore'),
                    icon: const Icon(Icons.open_with, size: 18),
                    onPressed: controller.busy
                        ? null
                        : () => controller.show(true, restore: true),
                    label: const Text('恢复字幕操作并重置位置'),
                  ),
                ),
                if (_error != null || controller.error != null)
                  Text(
                    _error ?? controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const Text(
                  '样式和远程兼容设置保存后生效；显示和穿透状态不会随重启恢复。',
                  style: TextStyle(fontSize: 12, color: Color(0xff708196)),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            key: const Key('overlay-save'),
            onPressed: _saving
                ? null
                : () async {
                    setState(() {
                      _saving = true;
                      _error = null;
                    });
                    try {
                      await controller.save(_settings);
                      if (context.mounted) Navigator.pop(context);
                    } catch (_) {
                      if (mounted) {
                        setState(() => _error = '无法保存字幕样式，请检查存储权限后重试');
                      }
                    } finally {
                      if (mounted) setState(() => _saving = false);
                    }
                  },
            child: Text(_saving ? '正在保存…' : '保存样式'),
          ),
        ],
      );
    },
  );
  Widget _slider(
    String label,
    String value,
    double current,
    double min,
    double max,
    int divisions,
    void Function(double) changed,
  ) => Row(
    children: [
      SizedBox(width: 104, child: Text(label)),
      Expanded(
        child: Slider(
          value: current,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: _saving ? null : (value) => setState(() => changed(value)),
        ),
      ),
      SizedBox(width: 42, child: Text(value)),
    ],
  );
}

class _SubtitlePreview extends StatefulWidget {
  const _SubtitlePreview({required this.settings});
  final OverlaySettings settings;
  @override
  State<_SubtitlePreview> createState() => _SubtitlePreviewState();
}

class _SubtitlePreviewState extends State<_SubtitlePreview> {
  ui.Image? _image;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void didUpdateWidget(_SubtitlePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _render();
  }

  Future<void> _render() async {
    final token = ++_generation;
    final image = await renderSubtitles(
      width: 520,
      height: 132,
      scale: 1,
      settings: widget.settings,
      locked: true,
      status: '',
      rows: subtitleRows(
        widget.settings,
        ['We need to leave before sunrise.'],
        ['我们得在日出前离开。'],
      ),
    );
    if (!mounted || token != _generation) {
      image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = image;
    });
  }

  @override
  void dispose() {
    ++_generation;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: ColoredBox(
      color: const Color(0xff708196),
      child: RawImage(image: _image, fit: BoxFit.contain),
    ),
  );
}
