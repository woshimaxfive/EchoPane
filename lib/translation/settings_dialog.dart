import 'package:flutter/material.dart';

import 'provider.dart';
import 'settings.dart';
import 'translation_controller.dart';

Future<void> showTranslationSettings(
  BuildContext context,
  TranslationController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => TranslationSettingsDialog(controller: controller),
);

class TranslationSettingsDialog extends StatefulWidget {
  const TranslationSettingsDialog({super.key, required this.controller});
  final TranslationController controller;
  @override
  State<TranslationSettingsDialog> createState() =>
      _TranslationSettingsDialogState();
}

class _TranslationSettingsDialogState extends State<TranslationSettingsDialog> {
  late final TextEditingController _url;
  late final TextEditingController _model;
  final _key = TextEditingController();
  late String _source;
  late String _target;
  late bool _jsonMode;
  late bool _disableThinking;
  bool _custom = false;
  bool _showKey = false;
  bool _busy = false;
  String? _message;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    final settings = widget.controller.settings;
    _url = TextEditingController(text: settings.baseUrl);
    _model = TextEditingController(text: settings.model);
    _source = settings.source;
    _target = settings.target;
    _jsonMode = settings.jsonMode;
    _disableThinking = settings.disableThinking;
    _custom = settings.endpoint.host != 'api.deepseek.com';
  }

  TranslationSettings _settings() => TranslationSettings(
    baseUrl: _url.text.trim(),
    model: _model.text.trim(),
    source: _source,
    target: _target,
    jsonMode: _jsonMode,
    disableThinking: _disableThinking,
  );
  String? get _newKey => _key.text.trim().isEmpty ? null : _key.text.trim();

  Future<void> _run(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } on TranslationFailure catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = '操作失败，请检查设置和 Windows 凭据服务';
          _failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.controller.cancelTest();
    _url.dispose();
    _model.dispose();
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('翻译服务'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('开启翻译后，识别出的文字会发送到此服务。截图留在本机。'),
            const SizedBox(height: 18),
            DropdownButtonFormField<bool>(
              initialValue: _custom,
              decoration: const InputDecoration(
                labelText: '服务类型',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: false, child: Text('DeepSeek 官方')),
                DropdownMenuItem(value: true, child: Text('自定义兼容服务')),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _custom = value!;
                      if (!_custom) {
                        _url.text = 'https://api.deepseek.com';
                        _model.text = 'deepseek-flash';
                        _jsonMode = true;
                        _disableThinking = true;
                      } else {
                        _disableThinking = false;
                      }
                    }),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('translation-url'),
              controller: _url,
              enabled: !_busy && _custom,
              maxLength: 2048,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '服务地址',
                hintText: 'https://example.com/v1',
                helperText: '远程地址使用 HTTPS，本机服务可使用 HTTP',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('translation-model'),
              controller: _model,
              enabled: !_busy,
              maxLength: 128,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '模型名称',
                counterText: '',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('translation-key'),
              controller: _key,
              enabled: !_busy,
              obscureText: !_showKey,
              enableSuggestions: false,
              autocorrect: false,
              maxLength: 2048,
              decoration: InputDecoration(
                labelText: 'API Key',
                counterText: '',
                border: const OutlineInputBorder(),
                helperText: widget.controller.hasKey
                    ? '已保存 Key；留空保留，更换服务主机时需重新填写'
                    : '保存在 Windows 凭据管理器，本机无鉴权服务可留空',
                suffixIcon: IconButton(
                  tooltip: _showKey ? '隐藏 Key' : '显示 Key',
                  onPressed: _busy
                      ? null
                      : () => setState(() => _showKey = !_showKey),
                  icon: Icon(
                    _showKey
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _source,
                    decoration: const InputDecoration(
                      labelText: '源语言',
                      border: OutlineInputBorder(),
                    ),
                    items: translationLanguages.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _source = value!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _target,
                    decoration: const InputDecoration(
                      labelText: '目标语言',
                      border: OutlineInputBorder(),
                    ),
                    items: translationLanguages.entries
                        .where((entry) => entry.key != 'auto')
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _target = value!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ExpansionTile(
              title: const Text('高级兼容设置'),
              tilePadding: EdgeInsets.zero,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('使用 JSON 输出模式'),
                  subtitle: const Text('服务不支持此参数时关闭，仍需模型返回完整段落'),
                  value: _jsonMode,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _jsonMode = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('发送关闭思考参数'),
                  subtitle: const Text('DeepSeek 预设启用；其他服务按实际支持情况设置'),
                  value: _disableThinking,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _disableThinking = value),
                ),
              ],
            ),
            const Text(
              '测试会发送一句固定文本，可能产生服务费用。保存后需在主窗口手动开启翻译。',
              style: TextStyle(fontSize: 12, color: Color(0xff708196)),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _message!,
                  key: const Key('translation-settings-message'),
                  style: TextStyle(
                    color: _failed
                        ? Theme.of(context).colorScheme.error
                        : const Color(0xff167c80),
                  ),
                ),
              ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.controller.hasKey)
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await widget.controller.removeKey();
                  if (mounted) {
                    setState(() {
                      _key.clear();
                      _message = '已删除保存的 Key';
                      _failed = false;
                    });
                  }
                }),
          child: const Text('删除 Key'),
        ),
      TextButton(
        onPressed: _busy
            ? null
            : () => _run(() async {
                final value = await widget.controller.testConnection(
                  _settings(),
                  _newKey,
                );
                if (mounted) {
                  setState(() {
                    _message = '测试成功：$value';
                    _failed = false;
                  });
                }
              }),
        child: const Text('测试连接'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        key: const Key('translation-save'),
        onPressed: _busy
            ? null
            : () => _run(() async {
                await widget.controller.configure(_settings(), newKey: _newKey);
                if (context.mounted) Navigator.pop(context);
              }),
        child: const Text('保存'),
      ),
    ],
  );
}
