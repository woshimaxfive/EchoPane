import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const translationLanguages = {
  'auto': '自动判断',
  'zh-Hans': '简体中文',
  'zh-Hant': '繁体中文',
  'en': '英语',
  'ja': '日语',
  'ko': '韩语',
  'fr': '法语',
  'de': '德语',
  'es': '西班牙语',
};

class TranslationSettings {
  const TranslationSettings({
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.source = 'auto',
    this.target = 'zh-Hans',
    this.jsonMode = true,
    this.disableThinking = true,
  });
  final String baseUrl;
  final String model;
  final String source;
  final String target;
  final bool jsonMode;
  final bool disableThinking;

  Uri get endpoint {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        baseUrl.length > 2048) {
      throw const FormatException('请填写有效的服务地址，不包含密码、查询参数或片段');
    }
    final local = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
      throw const FormatException('远程服务必须使用 HTTPS；HTTP 仅支持本机地址');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/chat/completions')
          ? path
          : '$path/chat/completions',
    );
  }

  void validate() {
    endpoint;
    if (model.trim().isEmpty ||
        model.length > 128 ||
        model.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('请填写有效的模型名称');
    }
    if (!translationLanguages.containsKey(source) ||
        target == 'auto' ||
        !translationLanguages.containsKey(target)) {
      throw const FormatException('请选择源语言和目标语言');
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'baseUrl': baseUrl,
    'model': model,
    'source': source,
    'target': target,
    'jsonMode': jsonMode,
    'disableThinking': disableThinking,
  };
  factory TranslationSettings.fromJson(Map<String, dynamic> json) =>
      TranslationSettings(
        baseUrl: json['baseUrl'] as String? ?? 'https://api.deepseek.com',
        model: json['model'] as String? ?? 'deepseek-flash',
        source: json['source'] as String? ?? 'auto',
        target: json['target'] as String? ?? 'zh-Hans',
        jsonMode: json['jsonMode'] as bool? ?? true,
        disableThinking: json['disableThinking'] as bool? ?? true,
      );
}

abstract interface class CredentialStore {
  Future<String?> read();
  Future<void> write(String key);
  Future<void> delete();
}

class WindowsCredentialStore implements CredentialStore {
  const WindowsCredentialStore({this.testing = false});
  final bool testing;
  MethodChannel get _channel => MethodChannel(
    testing ? 'echopane/credentials_test' : 'echopane/credentials',
  );
  @override
  Future<String?> read() => _channel.invokeMethod<String>('read');
  @override
  Future<void> write(String key) => _channel.invokeMethod<void>('write', key);
  @override
  Future<void> delete() => _channel.invokeMethod<void>('delete');
}

abstract interface class SettingsStore {
  Future<TranslationSettings> read();
  Future<void> write(TranslationSettings settings);
}

class FileSettingsStore implements SettingsStore {
  FileSettingsStore({String? path})
    : path =
          path ??
          '${Platform.environment['LOCALAPPDATA']}/EchoPane/translation.json';
  final String path;
  @override
  Future<TranslationSettings> read() async {
    final file = File(path);
    if (!await file.exists()) return const TranslationSettings();
    if (await file.length() > 16384) throw const FormatException('配置文件过大');
    final settings = TranslationSettings.fromJson(
      jsonDecode(await file.readAsString(encoding: utf8))
          as Map<String, dynamic>,
    );
    settings.validate();
    return settings;
  }

  @override
  Future<void> write(TranslationSettings settings) async {
    settings.validate();
    final file = File(path);
    await file.parent.create(recursive: true);
    final temporary = File('$path.tmp');
    await temporary.writeAsString(
      jsonEncode(settings.toJson()),
      encoding: utf8,
      flush: true,
    );
    await temporary.rename(path);
  }
}
