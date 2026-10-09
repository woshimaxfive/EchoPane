import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../subtitles/caption_source.dart';
import '../translation/settings.dart';
import 'caption_history.dart';
import 'history_exporter.dart';

Future<void> showCaptionHistory(
  BuildContext context,
  CaptionHistory history, {
  HistoryExporter? exporter,
}) => showDialog<void>(
  context: context,
  builder: (_) => _HistoryDialog(
    history: history,
    exporter: exporter ?? DesktopHistoryExporter(),
  ),
);

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.history, required this.exporter});
  final CaptionHistory history;
  final HistoryExporter exporter;
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  bool _busy = false;
  String? _message;
  HistoryFormat _format = HistoryFormat.text;

  Future<void> _act(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    String? message;
    try {
      message = await action();
    } catch (_) {
      message = '操作失败，请检查剪贴板或文件权限后重试。';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = message;
        });
      }
    }
  }

  Future<void> _copy(String text) => _act(() async {
    await Clipboard.setData(ClipboardData(text: text));
    return '已复制。';
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: RepaintBoundary(
        key: const Key('history-content'),
        child: SizedBox(
          width: math.min(700, size.width - 80),
          height: math.min(500, size.height - 48),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: AnimatedBuilder(
              animation: widget.history,
              builder: (context, _) {
                final entries = widget.history.entries;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '字幕记录',
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('history-close'),
                          tooltip: '关闭',
                          onPressed: _busy
                              ? null
                              : () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    Text(
                      '${entries.length} 条 · 仅保留在本次运行的内存中，退出后清空。',
                      style: const TextStyle(color: Color(0xff708196)),
                    ),
                    if (widget.history.dropped > 0)
                      Text(
                        '容量限制已移除 ${widget.history.dropped} 条较早记录。',
                        style: const TextStyle(color: Color(0xff708196)),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton.icon(
                          key: const Key('history-copy-all'),
                          onPressed: _busy || entries.isEmpty
                              ? null
                              : () => _copy(widget.history.snapshot().toText()),
                          icon: const Icon(Icons.copy, size: 17),
                          label: const Text('复制全部'),
                        ),
                        DropdownButton<HistoryFormat>(
                          key: const Key('history-format'),
                          value: _format,
                          underline: const SizedBox.shrink(),
                          items: const [
                            DropdownMenuItem(
                              value: HistoryFormat.text,
                              child: Text('TXT'),
                            ),
                            DropdownMenuItem(
                              value: HistoryFormat.json,
                              child: Text('JSON'),
                            ),
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _format = value!),
                        ),
                        FilledButton.tonalIcon(
                          key: const Key('history-export'),
                          onPressed: _busy || entries.isEmpty
                              ? null
                              : () {
                                  final snapshot = widget.history.snapshot();
                                  final format = _format;
                                  _act(() async {
                                    final path = await widget.exporter.save(
                                      snapshot,
                                      format,
                                    );
                                    return path == null ? null : '已导出到所选文件。';
                                  });
                                },
                          icon: const Icon(Icons.save_alt, size: 17),
                          label: const Text('导出'),
                        ),
                        TextButton(
                          key: const Key('history-clear'),
                          onPressed: _busy || entries.isEmpty
                              ? null
                              : () {
                                  widget.history.clear();
                                  setState(() => _message = '已清空本次记录。');
                                },
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                    const Divider(),
                    Expanded(
                      child: entries.isEmpty
                          ? const Center(
                              child: Text(
                                '开始识别后，字幕会记录在这里。',
                                style: TextStyle(color: Color(0xff708196)),
                              ),
                            )
                          : ListView.builder(
                              key: const Key('history-list'),
                              itemCount: entries.length,
                              itemBuilder: (context, index) {
                                final entry =
                                    entries[entries.length - 1 - index];
                                final time = entry.receivedAt
                                    .toLocal()
                                    .toIso8601String()
                                    .replaceFirst('T', ' ')
                                    .split('.')
                                    .first;
                                final origin =
                                    entry.origin == RecognitionMode.audio
                                    ? '音频'
                                    : '屏幕';
                                final target =
                                    translationLanguages[entry.target];
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '$time · $origin${target == null ? '' : ' · $target'}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: Color(0xff708196),
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: '复制这一条',
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: _busy
                                                ? null
                                                : () => _copy(
                                                    CaptionSnapshot(
                                                      [entry],
                                                      entry.receivedAt,
                                                      0,
                                                    ).toText(),
                                                  ),
                                            icon: const Icon(
                                              Icons.copy,
                                              size: 16,
                                            ),
                                          ),
                                        ],
                                      ),
                                      for (
                                        var i = 0;
                                        i < entry.originals.length;
                                        i++
                                      ) ...[
                                        SelectableText(entry.originals[i]),
                                        if (i < entry.translations.length)
                                          SelectableText(
                                            entry.translations[i],
                                            style: const TextStyle(
                                              color: Color(0xff167c80),
                                            ),
                                          ),
                                        if (i + 1 < entry.originals.length)
                                          const SizedBox(height: 6),
                                      ],
                                      if (entry.translations.isEmpty)
                                        const Text(
                                          '未翻译',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xff708196),
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    if (_message != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _message!,
                          key: const Key('history-message'),
                          maxLines: 2,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
