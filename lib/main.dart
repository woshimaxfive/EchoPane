import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'capture/capture_controller.dart';
import 'capture/capture_platform.dart';
import 'ocr/model_store.dart';
import 'ocr/ocr_controller.dart';
import 'ocr/ocr_panel.dart';
import 'translation/provider.dart';
import 'translation/settings.dart';
import 'translation/settings_dialog.dart';
import 'translation/translation_controller.dart';
import 'subtitles/overlay_controller.dart';
import 'subtitles/overlay_dialog.dart';
import 'subtitles/overlay_platform.dart';
import 'subtitles/overlay_settings.dart';

Future<void> main() => startApplication();

Future<void> startApplication({
  SettingsStore? settingsStore,
  CredentialStore? credentials,
  TranslationProvider? translationProvider,
  OverlayPlatform? overlayPlatform,
  OverlaySettingsStore? overlaySettingsStore,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await trayManager.setIcon('assets/app.ico');
  await trayManager.setToolTip('EchoPane · 随幕');
  await trayManager.setContextMenu(
    Menu(
      items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem(key: 'stop', label: '停止捕获'),
        MenuItem(key: 'subtitles', label: '显示悬浮字幕'),
        MenuItem(key: 'subtitle_restore', label: '恢复字幕操作'),
        MenuItem(key: 'subtitle_hide', label: '隐藏悬浮字幕'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ],
    ),
  );
  await windowManager.setAsFrameless();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(900, 720),
      minimumSize: Size(680, 520),
      center: true,
      backgroundColor: Colors.transparent,
      title: 'EchoPane · 随幕',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final controller = CaptureController(WindowsCapturePlatform());
  final models = OcrModelStore();
  final ocr = OcrController(controller, models, WindowsOcrPlatform());
  final translation = TranslationController(
    ocr,
    translationProvider ?? const ChatTranslationProvider(),
    settingsStore ?? FileSettingsStore(),
    credentials ?? const WindowsCredentialStore(),
  );
  final overlay = OverlayController(
    ocr,
    translation,
    overlayPlatform ?? WindowsOverlayPlatform(),
    overlaySettingsStore ?? FileOverlaySettingsStore(),
  );
  runApp(
    EchoPaneApp(
      controller: controller,
      ocr: ocr,
      translation: translation,
      overlay: overlay,
    ),
  );
  await controller.initialize();
  await models.check();
  await translation.initialize();
  await overlay.initialize();
}

class EchoPaneApp extends StatelessWidget {
  const EchoPaneApp({
    super.key,
    required this.controller,
    this.ocr,
    this.translation,
    this.overlay,
  });
  final CaptureController controller;
  final OcrController? ocr;
  final TranslationController? translation;
  final OverlayController? overlay;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EchoPane',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Segoe UI',
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff167c80),
        surface: const Color(0xfff5f7fa),
      ),
    ),
    home: RepaintBoundary(
      key: const Key('window-content'),
      child: CaptureWindow(
        controller: controller,
        ocr: ocr,
        translation: translation,
        overlay: overlay,
      ),
    ),
  );
}

class CaptureWindow extends StatefulWidget {
  const CaptureWindow({
    super.key,
    required this.controller,
    this.ocr,
    this.translation,
    this.overlay,
  });
  final CaptureController controller;
  final OcrController? ocr;
  final TranslationController? translation;
  final OverlayController? overlay;

  @override
  State<CaptureWindow> createState() => _CaptureWindowState();
}

class _CaptureWindowState extends State<CaptureWindow>
    with WindowListener, TrayListener {
  bool _pinned = false;
  double _opacity = 0.97;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() async {
    await widget.overlay?.close();
    await widget.controller.stop();
    await trayManager.destroy();
    await windowManager.destroy();
  }

  @override
  void onWindowMinimize() async {
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        onTrayIconMouseDown();
      case 'stop':
        widget.controller.stop();
      case 'subtitles':
        widget.overlay?.show(true);
      case 'subtitle_restore':
        widget.overlay?.show(true, restore: true);
      case 'subtitle_hide':
        widget.overlay?.close();
      case 'quit':
        onWindowClose();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DragToResizeArea(
    resizeEdgeSize: 9,
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: const Color(0xfff5f7fa).withValues(alpha: _opacity),
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) => _content(context, widget.controller),
          ),
        ),
      ),
    ),
  );

  Widget _content(BuildContext context, CaptureController state) {
    final status = switch (state.phase) {
      CapturePhase.idle => '待机',
      CapturePhase.selecting => '正在框选',
      CapturePhase.starting => '正在启动',
      CapturePhase.running => '正在捕获',
      CapturePhase.stopping => '正在停止',
      CapturePhase.failed => '捕获不可用',
    };
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: Row(
            children: [
              Expanded(
                child: DragToMoveArea(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 22),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.subtitles_outlined,
                          color: Color(0xff167c80),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'EchoPane',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          '随幕',
                          style: TextStyle(color: Color(0xff708196)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: _pinned ? '取消置顶' : '窗口置顶',
                isSelected: _pinned,
                icon: const Icon(Icons.push_pin_outlined, size: 19),
                selectedIcon: const Icon(Icons.push_pin, size: 19),
                onPressed: () async {
                  await windowManager.setAlwaysOnTop(!_pinned);
                  if (mounted) setState(() => _pinned = !_pinned);
                },
              ),
              IconButton(
                tooltip: '最小化',
                onPressed: windowManager.minimize,
                icon: const Icon(Icons.remove, size: 19),
              ),
              IconButton(
                tooltip: '退出',
                onPressed: windowManager.close,
                icon: const Icon(Icons.close, size: 19),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xffdae2e7)),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '屏幕翻译',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          color: Color(0xff243247),
                        ),
                      ),
                    ),
                    if (widget.overlay != null)
                      TextButton.icon(
                        key: const Key('overlay-settings'),
                        onPressed: () =>
                            showOverlaySettings(context, widget.overlay!),
                        icon: const Icon(
                          Icons.picture_in_picture_alt,
                          size: 18,
                        ),
                        label: const Text('悬浮字幕'),
                      ),
                    if (widget.translation != null)
                      TextButton.icon(
                        key: const Key('translation-settings'),
                        onPressed: () => showTranslationSettings(
                          context,
                          widget.translation!,
                        ),
                        icon: const Icon(Icons.tune, size: 18),
                        label: const Text('翻译服务'),
                      ),
                    const SizedBox(width: 12),
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: state.running
                          ? const Color(0xff167c80)
                          : const Color(0xff708196),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      status,
                      style: const TextStyle(color: Color(0xff708196)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  '选择关注的画面，截图和文字识别都在本机处理。',
                  style: TextStyle(color: Color(0xff708196)),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButton<CaptureDisplay>(
                        isExpanded: true,
                        value: state.display,
                        hint: const Text('正在读取显示器'),
                        items: state.displays
                            .map(
                              (d) => DropdownMenuItem(
                                value: d,
                                child: Text(
                                  '${d.name}  ${d.width} × ${d.height}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: state.busy
                            ? null
                            : (value) {
                                if (value != null) state.chooseDisplay(value);
                              },
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: state.busy || state.display == null
                          ? null
                          : state.selectRegion,
                      icon: const Icon(Icons.crop, size: 18),
                      label: const Text('框选区域'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: state.busy || state.display == null
                          ? null
                          : state.useFullDisplay,
                      child: const Text('整块屏幕'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  flex: 2,
                  child: Container(
                    width: double.infinity,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: _opacity),
                      border: Border.all(color: const Color(0xffdae2e7)),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: state.textureId == null
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              if (constraints.maxHeight < 160) {
                                return Center(
                                  child: Text(
                                    state.error ?? '框选一个区域，或选择整块屏幕',
                                    textAlign: TextAlign.center,
                                  ),
                                );
                              }
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.crop_free,
                                        size: 38,
                                        color: Color(0xff708196),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        state.error ?? '框选一个区域，或选择整块屏幕',
                                        textAlign: TextAlign.center,
                                      ),
                                      const SizedBox(height: 7),
                                      const Text(
                                        '点击开始后显示实时画面',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: Color(0xff708196),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )
                        : Center(
                            child: AspectRatio(
                              aspectRatio:
                                  (state.snapshot != null &&
                                          state.snapshot!.width > 0
                                      ? state.snapshot!.width
                                      : state.region?.width ??
                                            state.display!.width) /
                                  (state.snapshot != null &&
                                          state.snapshot!.height > 0
                                      ? state.snapshot!.height
                                      : state.region?.height ??
                                            state.display!.height),
                              child: Texture(textureId: state.textureId!),
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.ocr != null) ...[
                  const Divider(height: 1, color: Color(0xffdae2e7)),
                  Expanded(
                    flex: 3,
                    child: OcrPanel(
                      controller: widget.ocr!,
                      translation: widget.translation,
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.region == null
                            ? '范围：整块显示器'
                            : '范围：${state.region!.width} × ${state.region!.height} 像素',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff708196),
                        ),
                      ),
                    ),
                    if (state.snapshot != null)
                      Text(
                        '已捕获 ${state.snapshot!.frames} 帧',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff708196),
                        ),
                      ),
                    const SizedBox(width: 14),
                    FilledButton.icon(
                      key: const Key('capture-toggle'),
                      onPressed: state.busy || state.display == null
                          ? null
                          : state.running
                          ? state.stop
                          : state.start,
                      icon: Icon(
                        state.running ? Icons.stop : Icons.play_arrow,
                        size: 19,
                      ),
                      label: Text(state.running ? '停止' : '开始'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xffdae2e7)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 5),
          child: Row(
            children: [
              const Text(
                '窗口透明度',
                style: TextStyle(fontSize: 12, color: Color(0xff708196)),
              ),
              SizedBox(
                width: 150,
                child: Slider(
                  value: _opacity,
                  min: 0.55,
                  max: 1,
                  onChanged: (value) => setState(() => _opacity = value),
                ),
              ),
              const Spacer(),
              const Text(
                '本地识别 · 按需联网翻译',
                style: TextStyle(fontSize: 12, color: Color(0xff708196)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
