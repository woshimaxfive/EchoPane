import 'dart:convert';
import 'dart:io';

import 'screen_renderer.dart';

class ScreenOverlaySettings {
  const ScreenOverlaySettings({
    this.mode = ScreenTranslationMode.below,
    this.fontScale = 1,
    this.allowCapture = true,
  });
  final ScreenTranslationMode mode;
  final double fontScale;
  final bool allowCapture;
  ScreenOverlaySettings copyWith({
    ScreenTranslationMode? mode,
    double? fontScale,
    bool? allowCapture,
  }) => ScreenOverlaySettings(
    mode: mode ?? this.mode,
    fontScale: fontScale ?? this.fontScale,
    allowCapture: allowCapture ?? this.allowCapture,
  );
  void validate() {
    if (!fontScale.isFinite || fontScale < 0.7 || fontScale > 1.5) {
      throw const FormatException('原位翻译字号超出范围');
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'mode': mode.name,
    'fontScale': fontScale,
    'allowCapture': allowCapture,
  };
  factory ScreenOverlaySettings.fromJson(Map<String, dynamic> json) {
    final settings = ScreenOverlaySettings(
      mode: ScreenTranslationMode.values.byName(json['mode'] as String),
      fontScale: (json['fontScale'] as num).toDouble(),
      allowCapture: json['allowCapture'] as bool,
    );
    settings.validate();
    return settings;
  }
}

abstract interface class ScreenOverlaySettingsStore {
  Future<ScreenOverlaySettings> read();
  Future<void> write(ScreenOverlaySettings settings);
}

class FileScreenOverlaySettingsStore implements ScreenOverlaySettingsStore {
  FileScreenOverlaySettingsStore({String? path})
    : path =
          path ??
          '${Platform.environment['LOCALAPPDATA']}/EchoPane/screen-overlay.json';
  final String path;
  @override
  Future<ScreenOverlaySettings> read() async {
    final file = File(path);
    if (!await file.exists()) return const ScreenOverlaySettings();
    if (await file.length() > 4096) throw const FormatException('原位翻译配置过大');
    return ScreenOverlaySettings.fromJson(
      jsonDecode(await file.readAsString(encoding: utf8))
          as Map<String, dynamic>,
    );
  }

  @override
  Future<void> write(ScreenOverlaySettings settings) async {
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
