# EchoPane 实时字幕

为视频、课程、播客和直播显示实时原文、中文字幕或双语字幕。安装包适用于 Windows 11 x64，使用实时字幕时需要联网。双击 MSI 安装，从开始菜单打开 EchoPane。

如果 MSI 提示缺少 Microsoft Visual C++ x64 运行库，请先安装微软提供的官方运行库，再打开 MSI。 [微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

点击左栏顶部的箭头收起或展开导航。收起时鼠标停在图标上可查看页名。再次打开 EchoPane 时会恢复上次使用的侧栏状态。

主窗口首次在主屏中央打开，回看和快捷键设置首次在主窗口所在屏幕居中，字幕浮窗从同一屏幕的底部居中出现。各窗口会记住自己的位置。重新打开时，超出当前屏幕可用区域的位置会移回可见范围。

1. 在「设置」中填入自己的百炼北京地域 API Key。使用指定业务空间时，在「高级设置」填写空间 ID。
2. 回到「实时字幕」，从「音源」列表选择正在播放的窗口。想一起听多个应用时，手动选「全系统声音（默认输出）」。它采集开始时 Windows 默认播放设备上的混音。刚打开其他窗口时，点「刷新」更新列表。
3. 点击「开始字幕」，输入电平会随所选音源的声音变化。首条字幕出现前，状态区会显示等待声音或已收到声音、正在等待字幕。收起主窗后字幕会继续显示。点击「停止字幕」后，程序释放音源并等待最后一段字幕。服务返回用量时，主窗底部会显示音频输入和文本输出的 Token 数。

要更换音源或字幕内容，先停止字幕，再选择后重新开始。所选程序关闭后可以刷新列表。更改 Windows 默认播放设备后，重新开始一场全系统声音字幕即可使用新的默认设备。

在「字幕外观」页点「显示字幕」打开浮窗，同一个按钮会变成「关闭字幕」。这里也可以预览字号、透明或窄暗底，并锁定浮窗位置。浮窗默认显示带细描边的字幕，单句超出屏幕可用宽度时换行。浮窗按内容扩展，字幕变短时稍停再收拢。鼠标移到文字上时出现半透明操作区，文字保持原有对比度，可以按住字幕或空白处拖动。操作区有字号、背景、锁定、停止和关闭控件。移开鼠标后恢复观看状态。背景、字号、位置和锁定状态会自动保存。

在开始前打开「字幕外观 → 字幕内容」。选择「仅原文」时，浮窗、回看和导出使用百炼返回的识别原文。「双语」会先显示译文，对应原文确认后出现在上方。三种模式均使用现有的百炼实时服务及其用量记录。字幕内容选项会自动保存，新安装默认选择「仅译文」。

在「实时字幕」点「字幕回看」，独立窗口会定位到过去 30 秒内最早显示的字幕，长时间没出字幕时定位到最后一条。回看时，浮窗继续更新，列表停在阅读位置。点「回到最新」恢复跟随，点「刚才 30 秒」再次定位。翻译中断时可按提示重新开始。

默认用 `Ctrl+Alt+F7` 显示或隐藏字幕浮窗，用 `Ctrl+Alt+F9` 打开或切回字幕回看。切到播放器后也可以用，隐藏浮窗期间字幕会话继续运行。

在「设置 → 快捷键」点击「录制」后按键，也可在框里直接输入，例如 `Ctrl+Shift+K` 或 `F6`。按 `Esc` 可取消录制。可以分别停用，也可以恢复默认。点击「保存」后即时生效，重开 EchoPane 会沿用已保存的快捷键。遇到重复或注册冲突时，设置窗口会提示，当前配置继续生效。

用回看窗口上方的下拉框选场次，在「查找本场」输入关键词。也可以按 `Ctrl+F` 定位到查找框。查找匹配这场字幕中已有的原文和译文，英文字母忽略大小写。点击「上一处」「下一处」或按 `Shift+Enter`、`Enter` 跳到高亮结果。在输入框内按 `Esc` 清空查找。导出包含选中场次的完整字幕。

想留住一场字幕时，点回看窗口里的「保存本场」。会话结束时会补存这一场后续收到的字幕。重新打开 EchoPane 后，可以从回看窗口上方按时间选场次，也能从「用量」页选中有可用字幕的会话，点「回看这场」。未手动保存的字幕保留到下一场开始或软件退出。点击「导出…」可以把正在回看的字幕另存为 TXT 或 SRT。SRT 以本场开始为零点，时间码依据每条字幕首次显示的时间。

保存的会话字幕位于 `%LOCALAPPDATA%\EchoPane\captions.sqlite3`。数据库包含字幕文本、会话开始时间、时长和各句出现时间。升级后仍可在回看中打开和导出旧版本保存的字幕。

在「用量」页按今天、近 7 天或近 30 天查看会话数、音频输入 Token、文本输出 Token 和估算费用。点击上方指标切换趋势，鼠标移到图表上查看对应时段的数值。趋势和明细按会话开始时间统计。翻译期间显示服务最新返回的累计用量，结束或中断后写入本机记录。服务未返回用量时，明细以「—」显示。费用按北京地域公开单价估算，实际金额以百炼账单为准。 [百炼模型价格](https://help.aliyun.com/zh/model-studio/model-pricing)

用量保存在 `%LOCALAPPDATA%\EchoPane\usage.sqlite3`，每条记录包含会话时间、时长、模型、Token 数、估算费用和结束状态。

开始后，所选窗口的进程树音频会发往阿里云，使用量计入自己的百炼账户。浏览器同一进程树中其他标签页的声音也可能被采集。

点击「保存配置」可将 Key 和业务空间 ID 保存到当前 Windows 用户的凭据管理器，重新打开时会自动填入。单次试用可以直接开始。卸载前可在软件里点「清除配置」，也可在 Windows 凭据管理器删除 `EchoPane/Bailian/Beijing`。

点击「测试连接」可以让百炼验证当前填写的 Key、业务空间和实时字幕配置。测试只交换连接和配置消息，可以在保存之前进行，也不会添加用量会话。成功后，在「实时字幕」选择音源并点击「开始字幕」即可使用。 [百炼实时字幕连接协议](https://help.aliyun.com/zh/model-studio/livetranslate-realtime-websocket-access)

[百炼 API Key 获取说明](https://help.aliyun.com/zh/model-studio/get-api-key)

字幕示例照片由美国国家公园管理局拍摄，来自公有领域档案。 [照片来源](https://npgallery.nps.gov/AssetDetail/f1a8781f-9110-4676-81b0-3f88b658b8ca)

## 屏幕翻译

在「屏幕翻译」点击「框选屏幕」，拖动鼠标圈住文字，按 Esc 或右键取消。截图在内存中通过安装包自带的 RapidOCR 模型识别。识别后可以编辑原文。

EchoPane 运行时，可在播放器等其他窗口中按 `Ctrl+Alt+F6` 开始框选。点击「复用上次选区」或按 `Ctrl+Alt+F10`，会重新截取同一块区域并识别当前文字。这两个组合可在「设置 → 快捷键」中修改。重开 EchoPane 或更改显示器布局后，需要重新框选。

点击「翻译」后，EchoPane 用设置页的 Key 和业务空间向阿里云百炼 Qwen-MT 发送确认过的文字。译文为简体中文，可以选中或点击「复制」。截图留在本机内存，软件退出后清空本页文本。文本翻译用量可在百炼账单中查看，EchoPane 的「用量」页统计实时字幕会话。 [百炼 Qwen-MT 接口](https://help.aliyun.com/zh/model-studio/qwen-mt-api)

## 字幕文件翻译

1. 打开「字幕文件」，导入 SRT 或 WebVTT。页面显示可翻译的段数和第一段预览。读取失败时可将文件另存为 UTF-8 后再导入。
2. 点击「开始翻译」。字幕正文逐段发送给百炼，同一文件内重复的正文共用译文。位置、时间码和文件信息在本机处理。
3. 可点击「取消」。当前请求结束后停止，已完成的译文留在当前窗口。遇到请求错误时可重试，接着翻译还未完成的段落。
4. 完成后可「导出译文」或「导出双语」。另存的文件使用 UTF-8 和原时间轴，双语文件在每段原文后附上译文。WebVTT 的字幕编号和位置设置一并保留。

## 网页已有字幕

1. 打开 EchoPane 的「网页字幕」，点击「打开扩展目录」。在 Chrome 或 Edge 的扩展管理页开启开发者模式，点击「加载已解压的扩展」，选择 `browser_extension`。这一步每个浏览器配置做一次。安装新版本后可在扩展管理页重新加载该扩展。 [Chrome 加载步骤](https://developer.chrome.com/docs/extensions/get-started/tutorial/hello-world#load-unpacked) [Edge 加载步骤](https://learn.microsoft.com/en-us/microsoft-edge/extensions/getting-started/extension-sideloading)
2. 打开视频，在播放器里选中一条字幕轨。在 EchoPane 点击「开启连接」和「复制连接码」，再在视频标签页点开 EchoPane 扩展，粘贴并点击「连接当前标签页」。译文出现在桌面浮窗，随当前播放位置和所选字幕轨更新。换视频标签页时，先断开再复制新连接码。
3. 支持网页顶层 HTML5 视频通过浏览器标准接口提供并开启的字幕轨。如果播放器自行绘制字幕、视频位于跨站嵌入框或视频本身没有字幕，点击「使用播放声音转字幕」，再选音源开始。 [HTML 文本轨接口](https://html.spec.whatwg.org/multipage/media.html#text-track-api)

「字幕外观」的字幕内容、字号和背景也用于网页字幕。选择仅原文时可以直接在浮窗阅读。选择译文或双语时，EchoPane 按播放进度用现有 Key 把字幕正文发往百炼，并在本次连接中缓存译文。扩展和桌面端通过本机回环连接传递字幕及播放状态。文件和网页的文本翻译用量可在自己的百炼账单中查看。

## 术语词表

在「设置 → 术语词表」填写原文和指定译法，再点「添加术语」。点中已有词条可修改或删除。词表保存在 `%LOCALAPPDATA%\EchoPane\glossary.json`，可保存 100 条，原文和译法各限 80 个字符。

屏幕翻译、字幕文件、网页字幕和本地视频的文本翻译每次请求最多向百炼附带 20 条在原文中命中的术语。实时字幕在开始翻译时会提交整份词表。仅原文模式无需提交词条。词表为模型提供译法参考，实际结果取决于语音识别和翻译。 [百炼文本翻译术语参数](https://help.aliyun.com/zh/model-studio/qwen-mt-api) [百炼实时翻译热词](https://help.aliyun.com/zh/model-studio/qwen3-5-livetranslate-flash-realtime)

屏幕翻译的下一次请求会使用新词表。字幕文件取消后继续或重试时沿用该文件开始翻译时的词表。要改用新词表，可重新导入文件、重新连接网页字幕或重新开始一场实时字幕。

## 本地视频生成字幕

1. 打开「视频字幕」，点「导入视频…」选本机媒体文件。支持常见编码的 MP4、MOV、MKV、WebM、AVI 和 WMV，也可选择 M4A、WAV 或 MP3。多音轨文件会读取第一条音轨。
2. 点击「生成原文」。随安装包提供的 FFmpeg 在本机按视频的时间轴提取音轨，EchoPane 分段把音频发送给百炼 Fun-ASR-Flash。进度按已经转写的音频位置更新。图片和视频画面留在本机。 [Fun-ASR-Flash 接口](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)
3. 转写完成后可「导出原文」。需要中文字幕时点「翻译为双语」，沿用设置中的术语词表。再点「导出双语」，选 SRT 或 WebVTT。把导出的文件加载到原视频的播放器中，原文与译文共用同一时码。
4. 点击「取消」后等当前请求返回。当前窗口会保留已完成的片段，接着点「继续生成」或「继续翻译」。换文件或退出后需重新开始。无可读音轨、解码失败和服务请求错误会在页面提示。

转写按提交的音频时长计量，分段交接处包含少量重叠。双语另计文本翻译用量，金额以自己的百炼账单为准。EchoPane 的「用量」页统计实时字幕会话。 [百炼计费](https://help.aliyun.com/zh/model-studio/model-pricing)

## 本地原文字幕

1. 打开「实时字幕」，把「处理方式」切到「本地原文」。点击「下载模型」优先从魔搭获取 SenseVoiceSmall INT8 和词表，暂停后可再次点击继续下载。语音检测文件随安装包提供。已有模型文件通过校验后直接复用。
2. 选择播放窗口或全系统声音，点击「开始字幕」。模型就绪后在 CPU 上识别，可断网使用，无需 API Key。输出原文沿用现有浮窗、回看、保存本场和导出。
3. 需要实时译文或双语时，将「处理方式」切到「云端字幕」，再开始新一场。应用记住上次选择。文件损坏时可用「校验或修复」重新获取对应文件。

已取得 EchoPane 的 ZIP 模型包时，在「本地原文」点「导入模型包」并选择 ZIP。三个文件通过大小和 SHA-256 校验后安装到当前用户的模型目录，导入过程可断网完成。

本地模式按语音段出字幕，声音重叠、人名和数字的识别会受素材质量影响。模型自动识别普通话、粤语、英语、日语和韩语。 [模型说明及支持语言](https://k2-fsa.github.io/sherpa/onnx/sense-voice/)

需要构建配套模型包时，把已经通过校验的模型目录传给 `build_model_package.py`。从仓库根目录运行以下命令可将本机模型打成单独的 ZIP。

```powershell
python -B livecaption/build_model_package.py "$env:LOCALAPPDATA\EchoPane\models\sensevoice-int8-2024-07-17" `
    '.local/windows-package/EchoPane-SenseVoiceSmall-int8-2024-07-17.zip'
```

## 从源码运行

双击 `start.cmd`。需要 Python 3.12 x64（含 Tk），首次启动会在仓库的 `.local` 目录安装依赖。若提供了 `DASHSCOPE_API_KEY`，启动时使用该环境变量和对应的 `DASHSCOPE_WORKSPACE`。

从源码运行「视频字幕」时，按下面的构建步骤准备仓库内的解码器，或把 `ECHOPANE_FFMPEG_DIR` 指向已安装的 `ffmpeg.exe` 和 `ffprobe.exe` 所在目录。

## 界面结构

`app.py` 负责注册页面、连接主窗与浮窗。页面使用 `views.py` 中的现有控件和 `theme.py` 的共享样式。`capture.py` 从选定的播放窗口或默认播放设备采音，`session.py` 管理实时字幕会话、运行状态和本次字幕。`usage.py` 保存本机用量，`usage_view.py` 显示用量统计。`history.py` 显示并查找回看窗口的字幕，`transcripts.py` 保存和导出会话字幕。浮窗的 Windows 交互在 `overlay.py` 与 `caption_controls.py`，全局快捷键由 `shortcuts.py` 管理。

增加功能时可在独立页面中实现，复用主题，再把页面注册到主窗的左侧导航。各项功能可以在独立页面维护自身状态。

`screen_view.py` 管理屏幕翻译页面，`screen_capture.py` 负责 Windows 框选和截图，`screen_ocr.py` 调用本机模型，`text_translation.py` 发送确认后的文本。

`subtitle_view.py` 管理字幕文件页面和翻译进度，`subtitle_file.py` 负责格式导入与导出。页面通过 `text_translation.py` 复用现有的百炼连接。

`browser_extension` 负责读取授权标签页的字幕状态。`web_caption.py` 验证浏览器来源和一次性连接码，`web_caption_view.py` 跟随当前字幕更新桌面浮窗，复用现有文本翻译服务。

`glossary.py` 负责本机词表和文本匹配，`glossary_settings.py` 负责词表编辑窗口。文本翻译与实时字幕各自使用百炼对应的术语接口。

`video_view.py` 管理视频字幕的两阶段任务，`video_audio.py` 从 FFmpeg 的本机管道读取音轨，`video_asr.py` 调用转写接口，`video_captions.py` 根据逐词时间码生成字幕并共用格式库导出。

`offline_model.py` 管理模型获取和校验，`offline_speech.py` 将本地识别结果转成现有字幕事件。打包版的本地识别和屏幕 OCR 共用一份 ONNX Runtime。

## 构建 Windows 安装包

在仓库根目录使用带 Tk 的 Python 3.14.10 x64 创建构建环境。构建时会校验 SoXR、GEOS、FFmpeg 对应源码包以及 RapidOCR 模型的 SHA-256，并将它们放入安装包。

```powershell
py -3.14 -m venv .local/release-build
$buildPython = '.local/release-build/Scripts/python.exe'
& $buildPython -m pip install --only-binary=:all: -r livecaption/requirements-build.txt
New-Item -ItemType Directory -Force .local/windows-build/sources | Out-Null
$soxrSource = '.local/windows-build/sources/soxr-1.1.0.tar.gz'
if (!(Test-Path -LiteralPath $soxrSource)) {
    Invoke-WebRequest -Uri 'https://files.pythonhosted.org/packages/ed/11/27cebce4a108f77afea7c80545115536b45e3f11ebfb914f638fdd9ba847/soxr-1.1.0.tar.gz' -OutFile $soxrSource
}
$geosSource = '.local/windows-build/sources/geos-3.14.1.tar.bz2'
if (!(Test-Path -LiteralPath $geosSource)) {
    Invoke-WebRequest -Uri 'https://download.osgeo.org/geos/geos-3.14.1.tar.bz2' -OutFile $geosSource
}
$ffmpegSource = '.local/windows-build/sources/ffmpeg-9.1.tar.xz'
if (!(Test-Path -LiteralPath $ffmpegSource)) {
    Invoke-WebRequest -Uri 'https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz' -OutFile $ffmpegSource
}
```

在仓库根目录的 MSYS2 UCRT64 终端安装 `mingw-w64-ucrt-x86_64-gcc`、`make`、`diffutils` 和 `xz`，然后运行 `bash livecaption/build_ffmpeg.sh`。脚本校验源码包并构建音频解码用的 `ffmpeg.exe` 和 `ffprobe.exe`。回到刚创建构建环境的 PowerShell 运行下面两行。 [MSYS2 UCRT64](https://www.msys2.org/docs/environments/) [FFmpeg 源码发布](https://ffmpeg.org/download.html#release_9.1)

```powershell
& $buildPython -B livecaption/build_windows.py bdist_msi
Get-FileHash -Algorithm SHA256 .local/windows-package/EchoPane-0.2.35-win-x64.msi
```

生成的 x64 MSI 位于 `.local/windows-package/`。双击安装后，可从开始菜单打开 EchoPane。同一 Windows 用户下升级时，会沿用该用户的字幕外观与已保存的百炼凭据。

该安装包使用系统中的 Microsoft Visual C++ x64 运行库，安装时会检查所需文件。 [依赖许可与对应源码](../THIRD_PARTY_NOTICES.md)
