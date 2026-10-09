import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:echopane/capture/capture_controller.dart';
import 'package:echopane/ocr/model_store.dart';
import 'package:echopane/ocr/ocr_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'capture_controller_test.dart' show FakePlatform;

class FakeOcr implements OcrPlatform {
  Completer<Map<Object?, Object?>>? pending;
  int loads = 0;
  @override
  Future<void> load(String directory) async => loads++;
  @override
  Future<Map<Object?, Object?>> snapshot() async =>
      pending?.future ??
      {
        'ready': true,
        'loading': false,
        'lines': [
          {'text': '明日の朝', 'confidence': 0.95},
        ],
        'recognized': 1,
      };
}

void main() {
  test('stopped and replaced sessions reject late OCR output', () async {
    final capture = CaptureController(FakePlatform());
    await capture.initialize();
    final models = OcrModelStore(directory: 'unused')..phase = ModelPhase.ready;
    final platform = FakeOcr();
    final ocr = OcrController(capture, models, platform);
    await capture.start();
    await ocr.poll();
    expect(ocr.text, '明日の朝');
    platform.pending = Completer();
    final pending = ocr.poll();
    await capture.stop();
    await capture.start();
    platform.pending!.complete({
      'ready': true,
      'error': 'Old failure',
      'lines': [
        {'text': 'Old subtitle', 'confidence': 0.9},
      ],
    });
    await pending;
    expect(ocr.text, isEmpty);
    expect(ocr.error, isNull);
    platform.pending = null;
    await ocr.poll();
    expect(ocr.text, '明日の朝');
    await capture.stop();
    await ocr.poll();
    expect(ocr.text, isEmpty);
    ocr.dispose();
    models.dispose();
    capture.dispose();
  });

  test('download verifies bytes, rejects corruption and retries', () async {
    final directory = await Directory.systemTemp.createTemp('echopane-model-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final good = utf8.encode('本地模型测试');
    bool corrupt = true;
    int requests = 0;
    final subscription = server.listen((request) async {
      requests++;
      request.response.add(corrupt ? List.filled(good.length, 0) : good);
      await request.response.close();
    });
    final models = OcrModelStore(
      directory: directory.path,
      files: [
        OcrModelFile(
          'model.onnx',
          'http://127.0.0.1:${server.port}/model',
          sha256.convert(good).toString(),
          good.length,
        ),
      ],
    );
    try {
      await models.check();
      expect(models.phase, ModelPhase.missing);
      await models.download();
      expect(models.phase, ModelPhase.failed);
      expect(await File('${directory.path}/model.onnx').exists(), isFalse);
      expect(await File('${directory.path}/model.onnx.part').exists(), isFalse);
      corrupt = false;
      await models.download();
      expect(models.phase, ModelPhase.ready);
      await models.check();
      expect(models.phase, ModelPhase.ready);
      await models.download();
      expect(requests, 2, reason: 'Verified files are reused offline');
    } finally {
      models.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });

  test('cancelled download removes partial data and can retry', () async {
    final directory = await Directory.systemTemp.createTemp('echopane-cancel-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final body = List<int>.filled(8192, 7);
    final started = Completer<void>();
    final release = Completer<void>();
    bool slow = true;
    final subscription = server.listen((request) async {
      try {
        if (slow) {
          request.response.add(body.sublist(0, 100));
          await request.response.flush();
          started.complete();
          await release.future;
          request.response.add(body.sublist(100));
        } else {
          request.response.add(body);
        }
        await request.response.close();
      } catch (_) {
        // Cancellation closes the client's connection.
      }
    });
    final models = OcrModelStore(
      directory: directory.path,
      files: [
        OcrModelFile(
          'model.onnx',
          'http://127.0.0.1:${server.port}/model',
          sha256.convert(body).toString(),
          body.length,
        ),
      ],
    );
    try {
      await models.check();
      final download = models.download();
      await started.future;
      models.cancel();
      release.complete();
      await download;
      expect(models.phase, ModelPhase.missing);
      expect(await File('${directory.path}/model.onnx.part').exists(), isFalse);
      slow = false;
      await models.download();
      expect(models.phase, ModelPhase.ready);
    } finally {
      models.dispose();
      await subscription.cancel();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
}
