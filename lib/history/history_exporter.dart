import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'caption_history.dart';

enum HistoryFormat { text, json }

abstract interface class HistoryExporter {
  /// Returns null when the user cancels.
  Future<String?> save(CaptionSnapshot snapshot, HistoryFormat format);
}

typedef SavePathChooser = Future<String?> Function(
  String name,
  String extension,
);

/// Desktop file dialog is isolated from the history model and format logic.
class DesktopHistoryExporter implements HistoryExporter {
  DesktopHistoryExporter({SavePathChooser? choosePath})
    : _choosePath = choosePath ?? _desktopPath;
  final SavePathChooser _choosePath;

  static Future<String?> _desktopPath(String name, String extension) async =>
      (await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: [
          XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
        ],
      ))?.path;

  @override
  Future<String?> save(CaptionSnapshot snapshot, HistoryFormat format) async {
    final extension = format == HistoryFormat.json ? 'json' : 'txt';
    final date = snapshot.exportedAt.toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final path = await _choosePath('EchoPane-$date.$extension', extension);
    if (path == null) return null;
    final text = format == HistoryFormat.json
        ? snapshot.toJson()
        : snapshot.toText();
    await File(path).writeAsString(text, encoding: utf8, flush: true);
    return path;
  }
}
