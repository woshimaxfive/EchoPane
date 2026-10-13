import 'package:flutter/material.dart';

import 'capture_controller.dart';
import 'capture_platform.dart';

Future<void> showCaptureWindows(
  BuildContext context,
  CaptureController capture,
) async {
  try {
    final windows = await capture.targetWindows();
    if (!context.mounted) return;
    final target = await showDialog<CaptureTargetWindow>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('绑定要翻译的窗口'),
        content: SizedBox(
          width: 520,
          height: 300,
          child: windows.isEmpty
              ? const Center(child: Text('没有找到可捕获的窗口，请先打开播放器或浏览器'))
              : ListView(
                  children: [
                    for (final window in windows)
                      ListTile(
                        title: Text(
                          window.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, window),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target != null) await capture.chooseWindow(target);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法读取目标窗口，请恢复窗口后重试')));
    }
  }
}
