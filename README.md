# EchoPane

EchoPane 是面向 Windows 的实时字幕和屏幕翻译工具。选择播放窗口或 Windows 默认播放设备上的系统声音，就能在桌面浮窗里看原文、中文字幕或双语字幕。回看支持按场次查找关键词，字幕可保存在本机并导出 TXT 或 SRT。

[下载 0.2.41 安装包（Windows 11 x64）](https://github.com/woshimaxfive/EchoPane/releases/download/v0.2.41/EchoPane-0.2.41-win-x64.msi) · [预览版说明与校验清单](https://github.com/woshimaxfive/EchoPane/releases/tag/v0.2.41) · [问题反馈](https://github.com/woshimaxfive/EchoPane/issues)

## 开始使用

双击 MSI 安装，再从开始菜单打开 EchoPane。若安装程序提示缺少 Microsoft Visual C++ x64 运行库，请先装运行库，再运行 EchoPane MSI。 [微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

### 云端字幕（需要百炼 API Key）

1. 在「设置」填入自己的百炼北京地域 API Key。使用指定业务空间时，在「高级设置」填入空间 ID。点击「测试连接」。要在下次启动时沿用 Key，点击「保存配置」。 [百炼 API Key 获取说明](https://help.aliyun.com/zh/model-studio/get-api-key)
2. 播放外语视频或直播。在「实时字幕」把「处理方式」设为「云端字幕」，选择正在播放的窗口。要采集 Windows 默认播放设备上的声音，可选「全系统声音（默认输出）」。
3. 在「字幕外观 → 字幕内容」选择「仅译文」「仅原文」或「双语」，回到「实时字幕」点击「开始字幕」。

云端字幕需要联网。所选音源的音频会发往阿里云百炼，使用量计入自己的百炼账户。浏览器共用进程时，同一进程树中其他标签页的声音也可能被采集。 [使用与数据保存说明](livecaption/README.md)

### 本地原文（无需 API Key）

1. 在「实时字幕」把「处理方式」切到「本地原文」。点击「下载模型」，或下载 ZIP 后点击「导入模型包」并选择该文件。模型安装后约 229 MiB。 [下载 ZIP 模型包](https://github.com/woshimaxfive/EchoPane/releases/download/v0.2.37/EchoPane-SenseVoiceSmall-int8-2024-07-17.zip)
2. 模型就绪后选择正在播放的窗口或「全系统声音（默认输出）」，点击「开始字幕」。可以断网识别原文，使用同一个浮窗和回看。 [本地原文用法](livecaption/README.md#本地原文字幕)

## 其他功能

- 在「屏幕翻译」框选文字区域。在本机识别并按需修改原文，再点击「翻译」查看中文译文。 [屏幕翻译用法](livecaption/README.md#屏幕翻译)
- 在「字幕文件」导入 SRT 或 WebVTT，沿用百炼 Key 翻译，按原时间轴导出译文或双语字幕。 [字幕文件用法](livecaption/README.md#字幕文件翻译)
- 在「网页字幕」用随包扩展连接 Chrome 或 Edge 的视频标签页，将播放器已开启的 HTML5 字幕翻译到桌面浮窗。 [安装扩展与支持范围](livecaption/README.md#网页已有字幕)
- 在「设置 → 术语词表」保存常用人名、地名和术语的指定译法。 [词表使用说明](livecaption/README.md#术语词表)
- 在「视频字幕」导入本地视频，用已有百炼 Key 生成原文或双语字幕，按原视频时间码导出 SRT 或 WebVTT。 [视频字幕用法](livecaption/README.md#本地视频生成字幕)

## 问题反馈

反馈时请附上 EchoPane 版本、所用功能、复现步骤和界面提示。遇到浮窗显示问题，可以补充屏幕分辨率和 Windows 缩放比例。 [查看或提交问题](https://github.com/woshimaxfive/EchoPane/issues)

## 从源码运行和构建

使用带 Tk 的 Python 3.12 x64，运行 `livecaption/start.cmd`。构建 MSI 使用 Python 3.14 x64。 [完整构建步骤](livecaption/README.md#构建-windows-安装包)

## 许可

EchoPane 源码采用 MIT 许可证。第三方组件和预览素材采用各自的许可。 [项目许可证](LICENSE) [第三方许可与素材来源](THIRD_PARTY_NOTICES.md)
