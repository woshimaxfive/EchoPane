# EchoPane 实时字幕

为视频、课程、播客和直播显示实时中文字幕。安装包适用于 Windows 11 x64，使用实时字幕时需要联网。双击 MSI 安装，从开始菜单打开 EchoPane。

如果 MSI 提示缺少 Microsoft Visual C++ x64 运行库，请先安装微软提供的官方运行库，再打开 MSI。 [微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

点击左栏顶部的箭头收起或展开导航。收起时鼠标停在图标上可查看页名。再次打开 EchoPane 时会恢复上次使用的侧栏状态。

1. 在「设置」中填入自己的百炼北京地域 API Key。使用指定业务空间时，在「高级设置」填写空间 ID。
2. 回到「实时字幕」，从「播放窗口」列表选择正在播放的窗口。刚打开其他窗口时，点「刷新」更新列表。
3. 点击「开始字幕」，输入电平会随所选音源的声音变化。首条字幕出现前，状态区会区分等待声音和已经收到声音、正在等待首条译文。收起主窗后字幕会继续显示。点击「停止字幕」后，程序释放音源并等待最后一段译文。服务返回用量时，主窗底部会显示音频输入和文本输出的 Token 数。

要更换音源时，先停止字幕，再选择新的播放窗口。所选程序关闭后，刷新列表并重新选择即可开始下一场。

在「字幕外观」页可以预览字号、透明或窄暗底，并锁定浮窗位置。浮窗默认显示带细描边的字幕，单句超出屏幕可用宽度时换行。浮窗按内容扩展，字幕变短时稍停再收拢。鼠标移到文字上时出现半透明操作区，文字保持原有对比度，可以按住字幕或空白处拖动。操作区有字号、背景、锁定、停止和关闭控件。移开鼠标后恢复观看状态。背景、字号、位置和锁定状态会自动保存。

想同时看原文和译文时，在开始前选择「字幕外观 → 字幕内容 → 双语」。译文一到就显示，对应原文确认后出现在上方。回看、保存和导出都会带上已收到的原文。字幕内容选项会自动保存，新安装默认选择「仅译文」。

在「实时字幕」点「字幕回看」，独立窗口会定位到过去 30 秒内最早显示的字幕，长时间没出字幕时定位到最后一条。回看时，浮窗继续更新，列表停在阅读位置。点「回到最新」恢复跟随，点「刚才 30 秒」再次定位。翻译中断时可按提示重新开始。

想留住一场字幕时，点回看窗口里的「保存本场」。翻译结束时会补存这一场后续收到的译文。重新打开 EchoPane 后，可以从回看窗口上方按时间选场次，也能从「用量」页选中有可用字幕的会话，点「回看这场」。未手动保存的译文保留到下一场开始或软件退出。点击「导出…」可以把正在回看的字幕另存为 TXT 或 SRT。SRT 以本场开始为零点，时间码依据每条译文首次显示的时间。

保存的会话字幕位于 `%LOCALAPPDATA%\EchoPane\captions.sqlite3`。数据库包含字幕文本、会话开始时间、时长和各句出现时间。升级后仍可在回看中打开和导出旧版本保存的字幕。

在「用量」页按今天、近 7 天或近 30 天查看会话数、音频输入 Token、文本输出 Token 和估算费用。点击上方指标切换趋势，鼠标移到图表上查看对应时段的数值。趋势和明细按会话开始时间统计。翻译期间显示服务最新返回的累计用量，结束或中断后写入本机记录。服务未返回用量时，明细以「—」显示。费用按北京地域公开单价估算，实际金额以百炼账单为准。 [百炼模型价格](https://help.aliyun.com/zh/model-studio/model-pricing)

用量保存在 `%LOCALAPPDATA%\EchoPane\usage.sqlite3`，每条记录包含会话时间、时长、模型、Token 数、估算费用和结束状态。

开始后，所选窗口的进程树音频会发往阿里云，使用量计入自己的百炼账户。浏览器同一进程树中其他标签页的声音也可能被采集。

点击「保存配置」可将 Key 和业务空间 ID 保存到当前 Windows 用户的凭据管理器，重新打开时会自动填入。单次试用可以直接开始。卸载前可在软件里点「清除配置」，也可在 Windows 凭据管理器删除 `EchoPane/Bailian/Beijing`。

[百炼 API Key 获取说明](https://help.aliyun.com/zh/model-studio/get-api-key)

字幕示例照片由美国国家公园管理局拍摄，来自公有领域档案。 [照片来源](https://npgallery.nps.gov/AssetDetail/f1a8781f-9110-4676-81b0-3f88b658b8ca)

## 屏幕翻译

在「屏幕翻译」点击「框选屏幕」，拖动鼠标圈住文字，按 Esc 或右键取消。截图在内存中通过安装包自带的 RapidOCR 模型识别。识别后可以编辑原文。

点击「翻译」后，EchoPane 用设置页的 Key 和业务空间向阿里云百炼 Qwen-MT 发送确认过的文字。译文为简体中文，可以选中或点击「复制」。截图留在本机内存，软件退出后清空本页文本。文本翻译用量可在百炼账单中查看，EchoPane 的「用量」页统计实时字幕会话。 [百炼 Qwen-MT 接口](https://help.aliyun.com/zh/model-studio/qwen-mt-api)

## 从源码运行

双击 `start.cmd`。需要 Python 3.12 x64（含 Tk），首次启动会在仓库的 `.local` 目录安装依赖。若提供了 `DASHSCOPE_API_KEY`，启动时使用该环境变量和对应的 `DASHSCOPE_WORKSPACE`。

## 界面结构

`app.py` 负责注册页面、连接主窗与浮窗。页面使用 `views.py` 中的现有控件和 `theme.py` 的共享样式。`capture.py` 从选定的播放窗口采音，`session.py` 管理实时翻译会话、运行状态和本次译文。`usage.py` 保存本机用量，`usage_view.py` 显示用量统计。`history.py` 显示回看窗口，`transcripts.py` 保存和导出会话字幕。浮窗的 Windows 交互在 `overlay.py` 与 `caption_controls.py`。

增加功能时可在独立页面中实现，复用主题，再把页面注册到主窗的左侧导航。各项功能可以在独立页面维护自身状态。

`screen_view.py` 管理屏幕翻译页面，`screen_capture.py` 负责 Windows 框选和截图，`screen_ocr.py` 调用本机模型，`text_translation.py` 发送确认后的文本。

## 构建 Windows 安装包

在仓库根目录使用带 Tk 的 Python 3.14.10 x64 创建构建环境。构建时会校验 SoXR 与 GEOS 对应源码包以及 RapidOCR 模型的 SHA-256，并将它们放入安装包。

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
& $buildPython -B livecaption/build_windows.py bdist_msi
Get-FileHash -Algorithm SHA256 .local/windows-package/EchoPane-0.2.23-win-x64.msi
```

生成的 x64 MSI 位于 `.local/windows-package/`。双击安装后，可从开始菜单打开 EchoPane。同一 Windows 用户下升级时，会沿用该用户的字幕外观与已保存的百炼凭据。

该安装包使用系统中的 Microsoft Visual C++ x64 运行库，安装时会检查所需文件。 [依赖许可与对应源码](../THIRD_PARTY_NOTICES.md)
