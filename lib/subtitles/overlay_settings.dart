import 'dart:convert';
import 'dart:io';

enum SubtitleMode { bilingual, translated, original }

class OverlaySettings {
  const OverlaySettings({
    this.mode = SubtitleMode.bilingual,
    this.fontSize = 26,
    this.backgroundOpacity = 0.82,
    this.maxLines = 4,
  });
  final SubtitleMode mode;
  final double fontSize;
  final double backgroundOpacity;
  final int maxLines;
  OverlaySettings copyWith({
    SubtitleMode? mode,
    double? fontSize,
    double? backgroundOpacity,
    int? maxLines,
  }) => OverlaySettings(
    mode: mode ?? this.mode,
    fontSize: fontSize ?? this.fontSize,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    maxLines: maxLines ?? this.maxLines,
  );
  void validate() {
    if (!fontSize.isFinite ||
        fontSize < 16 ||
        fontSize > 48 ||
        !backgroundOpacity.isFinite ||
        backgroundOpacity < 0 ||
        backgroundOpacity > 1 ||
        maxLines < 2 ||
        maxLines > 10) {
      throw const FormatException('字幕样式超出允许范围');
    }
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'mode': mode.name,
    'fontSize': fontSize,
    'backgroundOpacity': backgroundOpacity,
    'maxLines': maxLines,
  };
  factory OverlaySettings.fromJson(Map<String, dynamic> value) {
    final settings = OverlaySettings(
      mode: SubtitleMode.values.byName(value['mode'] as String),
      fontSize: (value['fontSize'] as num).toDouble(),
      backgroundOpacity: (value['backgroundOpacity'] as num).toDouble(),
      maxLines: value['maxLines'] as int,
    );
    settings.validate();
    return settings;
  }
}

abstract interface class OverlaySettingsStore {
  Future<OverlaySettings> read();
  Future<void> write(OverlaySettings settings);
}

class FileOverlaySettingsStore implements OverlaySettingsStore {
  FileOverlaySettingsStore({String? path})
    : path =
          path ??
          '${Platform.environment['LOCALAPPDATA']}/EchoPane/subtitles.json';
  final String path;
  @override
  Future<OverlaySettings> read() async {
    final file = File(path);
    if (!await file.exists()) return const OverlaySettings();
    if (await file.length() > 4096) throw const FormatException('字幕配置过大');
    return OverlaySettings.fromJson(
      jsonDecode(await file.readAsString(encoding: utf8))
          as Map<String, dynamic>,
    );
  }

  @override
  Future<void> write(OverlaySettings settings) async {
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
