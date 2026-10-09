import 'dart:async';

/// Buffers brief OCR changes without guessing or rewriting recognized text.
class CaptionStabilizer<T> {
  CaptionStabilizer(
    this.publish, {
    this.firstDelay = const Duration(milliseconds: 120),
    this.changeDelay = const Duration(milliseconds: 500),
    this.emptyDelay = const Duration(milliseconds: 700),
    this.maximumWait = const Duration(milliseconds: 1200),
  });
  final void Function(List<T>) publish;
  final Duration firstDelay, changeDelay, emptyDelay, maximumWait;
  String _current = '';
  String? _pendingKey;
  List<T> _pending = [];
  bool _hasText = false;
  Timer? _settle;
  Timer? _maximum;
  bool get pending => _pendingKey != null;

  void submit(List<T> values, String key) {
    if (key == _current) {
      _cancel();
      return;
    }
    if (key == _pendingKey) return;
    _pending = List.unmodifiable(values);
    _pendingKey = key;
    _settle?.cancel();
    if (values.isEmpty) {
      _maximum?.cancel();
      _maximum = null;
    } else {
      _maximum ??= Timer(maximumWait, _commit);
    }
    final delay = values.isEmpty
        ? emptyDelay
        : _hasText
        ? changeDelay
        : firstDelay;
    if (delay == Duration.zero) {
      _commit();
    } else {
      _settle = Timer(delay, _commit);
    }
  }

  void _commit() {
    if (_pendingKey == null) return;
    final values = _pending;
    _current = _pendingKey!;
    _hasText = values.isNotEmpty;
    _cancel();
    publish(values);
  }

  void _cancel() {
    _settle?.cancel();
    _maximum?.cancel();
    _settle = null;
    _maximum = null;
    _pendingKey = null;
    _pending = [];
  }

  void reset() {
    _cancel();
    _current = '';
    _hasText = false;
  }

  void dispose() => _cancel();
}
