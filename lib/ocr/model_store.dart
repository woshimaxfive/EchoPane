import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class OcrModelFile {
  const OcrModelFile(this.name, this.url, this.sha256, this.size);
  final String name;
  final String url;
  final String sha256;
  final int size;
}

const _base =
    'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0';
const ocrModelFiles = [
  OcrModelFile(
    'det.onnx',
    '$_base/onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx',
    '4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae',
    4819576,
  ),
  OcrModelFile(
    'rec.onnx',
    '$_base/onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx',
    '5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5',
    16631306,
  ),
  OcrModelFile(
    'keys.txt',
    '$_base/paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt',
    'd1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b',
    74012,
  ),
];

enum ModelPhase { checking, missing, downloading, ready, failed }

class OcrModelStore extends ChangeNotifier {
  OcrModelStore({String? directory, this.files = ocrModelFiles})
    : directory =
          directory ??
          '${Platform.environment['LOCALAPPDATA']}/EchoPane/models/ppocrv5-mobile';

  final String directory;
  final List<OcrModelFile> files;
  ModelPhase phase = ModelPhase.checking;
  int received = 0;
  String? error;
  HttpClient? _client;
  bool _cancelled = false;
  bool _disposed = false;
  int get total => files.fold(0, (sum, file) => sum + file.size);

  Future<bool> _valid(OcrModelFile model, String path) => Isolate.run(() async {
    final file = File(path);
    if (!await file.exists() || await file.length() != model.size) return false;
    return (await sha256.bind(file.openRead()).first).toString() ==
        model.sha256;
  });

  Future<void> check() async {
    if (phase == ModelPhase.downloading || _disposed) return;
    phase = ModelPhase.checking;
    _notify();
    try {
      for (final model in files) {
        if (!await _valid(model, '$directory/${model.name}')) {
          phase = ModelPhase.missing;
          _notify();
          return;
        }
      }
      phase = ModelPhase.ready;
      error = null;
    } catch (_) {
      phase = ModelPhase.failed;
      error = '无法读取模型，请检查本机存储空间和文件权限';
    }
    _notify();
  }

  Future<void> download() async {
    if (phase == ModelPhase.downloading || phase == ModelPhase.checking) return;
    _cancelled = false;
    received = 0;
    phase = ModelPhase.downloading;
    error = null;
    _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    _notify();
    try {
      await Directory(directory).create(recursive: true);
      for (final model in files) {
        if (_cancelled) break;
        final path = '$directory/${model.name}';
        if (await _valid(model, path)) {
          received += model.size;
          _notify();
          continue;
        }
        final partial = File('$path.part');
        final request = await _client!.getUrl(Uri.parse(model.url));
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != HttpStatus.ok) throw HttpException('模型下载失败');
        if (response.contentLength > model.size) {
          throw const FormatException('模型大小不符');
        }
        final sink = partial.openWrite();
        int current = 0;
        try {
          await for (final bytes in response.timeout(
            const Duration(seconds: 30),
          )) {
            if (_cancelled) break;
            current += bytes.length;
            if (current > model.size) throw const FormatException('模型大小不符');
            sink.add(bytes);
            received += bytes.length;
            _notify();
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (_cancelled) {
          if (await partial.exists()) await partial.delete();
          break;
        }
        if (!await _valid(model, partial.path)) {
          throw const FormatException('模型校验失败');
        }
        if (await File(path).exists()) await File(path).delete();
        await partial.rename(path);
      }
      phase = _cancelled ? ModelPhase.missing : ModelPhase.ready;
    } catch (_) {
      phase = _cancelled ? ModelPhase.missing : ModelPhase.failed;
      error = _cancelled ? null : '模型下载或校验失败，请检查网络后重试';
    } finally {
      _client?.close(force: true);
      _client = null;
      for (final model in files) {
        try {
          final partial = File('$directory/${model.name}.part');
          if (await partial.exists()) await partial.delete();
        } catch (_) {
          // A locked temporary file is overwritten on the next attempt.
        }
      }
      _notify();
    }
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
