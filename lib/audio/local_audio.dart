import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../ocr/model_store.dart';
import 'streaming_audio.dart';

const _modelUrl =
    'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26/resolve/672fbf1b30579d6585301139bb363f42a0ad4a24';
const streamingModelFiles = [
  OcrModelFile(
    'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    '$_modelUrl/encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    '563fde436d16cf7607cf408cd6b30909819d03162652ef389c2450ced3f45ac1',
    71083163,
  ),
  OcrModelFile(
    'decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
    '$_modelUrl/decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
    '7bf787f90b194b307e5a4ad6a34fadb4e748304c35f78a8d66358a05b13ee6ef',
    2092621,
  ),
  OcrModelFile(
    'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    '$_modelUrl/joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    'd944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297',
    259335,
  ),
  OcrModelFile(
    'tokens.txt',
    '$_modelUrl/tokens.txt',
    '49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb',
    5048,
  ),
];

/// The inference library and native pointers stay inside a dedicated isolate.
class LocalAudioSession implements AudioStreamSession {
  LocalAudioSession(String directory) {
    _subscription = _messages.listen(_message);
    unawaited(_start(directory));
  }

  final _messages = ReceivePort();
  final _updates = StreamController<SpeechUpdate>();
  final _ready = Completer<void>();
  final _finished = Completer<void>();
  final _exited = Completer<void>();
  late final StreamSubscription<dynamic> _subscription;
  Isolate? _isolate;
  SendPort? _worker;
  int _pendingBytes = 0;
  bool _cancelled = false, _ending = false, _failed = false;

  @override
  Stream<SpeechUpdate> get updates => _updates.stream;
  @override
  Future<void> get ready => _ready.future;

  Future<void> _start(String directory) async {
    try {
      _isolate = await Isolate.spawn(
        _recognize,
        (_messages.sendPort, directory),
        onExit: _messages.sendPort,
        onError: _messages.sendPort,
      );
      if (_cancelled) _worker?.send('cancel');
    } catch (_) {
      _fail();
      if (!_exited.isCompleted) _exited.complete();
    }
  }

  void _fail() {
    if (_failed || _cancelled) return;
    _failed = true;
    const failure = AudioStreamFailure('本地实时识别暂不可用，请检查模型后重新开始');
    if (!_ready.isCompleted) {
      _ready.completeError(failure);
    } else {
      _updates.addError(failure);
    }
    if (!_finished.isCompleted) _finished.complete();
  }

  void _message(dynamic message) {
    if (message == null) {
      if (!_exited.isCompleted) _exited.complete();
      if (!_ending && !_cancelled) _fail();
    } else if (message is SendPort) {
      _worker = message;
      if (_cancelled) {
        message.send('cancel');
      } else if (!_ready.isCompleted) {
        _ready.complete();
      }
    } else if (message is int) {
      _pendingBytes -= message;
    } else if (message == 'finished') {
      if (!_finished.isCompleted) _finished.complete();
    } else if (message is SpeechUpdate) {
      if (!_cancelled && !_failed) _updates.add(message);
    } else {
      _fail();
    }
  }

  @override
  void addPcm(Uint8List pcm) {
    if (_cancelled || _ending || _failed) return;
    if (pcm.length.isOdd || _worker == null) {
      throw const AudioStreamFailure('本地音频帧不可用，请重新开始');
    }
    if (_pendingBytes + pcm.length > 16000 * 2 * 3) {
      throw const AudioStreamFailure('本地识别跟不上播放速度，请重新开始');
    }
    _pendingBytes += pcm.length;
    _worker!.send(TransferableTypedData.fromList([pcm]));
  }

  @override
  Future<void> finish() async {
    if (_cancelled) return;
    _ending = true;
    _worker?.send('finish');
    await _finished.future.timeout(const Duration(seconds: 5));
    if (_failed) throw const AudioStreamFailure('最后一段本地识别未完成');
    // Let the update stream deliver its final turn before the controller stops.
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    if (!_ready.isCompleted) _ready.complete();
    _worker?.send('cancel');
    try {
      await _exited.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _isolate?.kill(priority: Isolate.immediate);
    }
    await _subscription.cancel();
    _messages.close();
    await _updates.close();
  }
}

Future<void> _recognize((SendPort, String) args) async {
  final (output, directory) = args;
  final input = ReceivePort();
  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  try {
    sherpa.initBindings(
      Platform.isWindows ? File(Platform.resolvedExecutable).parent.path : null,
    );
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: '$directory/${streamingModelFiles[0].name}',
            decoder: '$directory/${streamingModelFiles[1].name}',
            joiner: '$directory/${streamingModelFiles[2].name}',
          ),
          tokens: '$directory/tokens.txt',
          numThreads: 1,
          provider: 'cpu',
          modelType: 'zipformer2',
        ),
        enableEndpoint: true,
        rule2MinTrailingSilence: 0.64,
        rule3MinUtteranceLength: 12,
      ),
    );
    stream = recognizer.createStream();
    var segment = 0;
    var previous = '';
    void decode({bool finished = false}) {
      while (recognizer!.isReady(stream!)) {
        recognizer.decode(stream);
      }
      final text = recognizer.getResult(stream).text.trim();
      final finalTurn = finished || recognizer.isEndpoint(stream);
      if (text.isNotEmpty && (text != previous || finalTurn)) {
        output.send(
          SpeechUpdate(
            id: 'local:$segment',
            source: text,
            translation: '',
            language: 'en',
            isFinal: finalTurn,
          ),
        );
      }
      if (finalTurn && !finished) {
        recognizer.reset(stream);
        segment++;
        previous = '';
      } else {
        previous = text;
      }
    }

    output.send(input.sendPort);
    await for (final message in input) {
      if (message == 'cancel') break;
      if (message == 'finish') {
        stream.acceptWaveform(samples: Float32List(12800), sampleRate: 16000);
        stream.inputFinished();
        decode(finished: true);
        output.send('finished');
        break;
      }
      if (message is TransferableTypedData) {
        final bytes = message.materialize().asUint8List();
        final data = ByteData.sublistView(bytes);
        final samples = Float32List(bytes.length ~/ 2);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
        }
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        decode();
        output.send(bytes.length);
      }
    }
  } catch (_) {
    output.send('failed');
  } finally {
    stream?.free();
    recognizer?.free();
    input.close();
  }
}
