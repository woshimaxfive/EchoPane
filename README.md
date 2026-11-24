# EchoPane

EchoPane 是面向 Windows 的实时字幕和屏幕翻译工具。选择播放窗口或 Windows 默认播放设备上的系统声音，就能在桌面浮窗里看原文、中文字幕或双语字幕。回看支持按场次查找关键词，字幕可保存在本机并导出 TXT 或 SRT。

## 开始使用

1. 获取 Windows 11 x64 的 EchoPane MSI 安装包。双击 MSI 安装，再从开始菜单打开 EchoPane。
2. 在「设置」填入自己的百炼北京地域 API Key。使用指定业务空间时，在「高级设置」填入空间 ID。
3. 在「实时字幕」选择播放窗口或「全系统声音（默认输出）」，点击「开始字幕」。在「字幕外观」可预先选择仅译文、仅原文或双语。
4. 在「屏幕翻译」框选文字区域。识别在本机完成，可以修改原文，再点击「翻译」查看中文译文。

如果安装程序提示缺少 Microsoft Visual C++ x64 运行库，请先装微软提供的运行库，再运行 EchoPane MSI。 [微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

实时翻译需要联网。所选音源的音频会发往阿里云百炼，使用量计入自己的百炼账户。浏览器共用进程时，同一进程树中其他标签页的声音也可能被采集。 [使用与数据保存说明](livecaption/README.md)

## 从源码运行和构建

使用带 Tk 的 Python 3.12 x64，运行 `livecaption/start.cmd`。构建 MSI 使用 Python 3.14 x64。 [完整构建步骤](livecaption/README.md#构建-windows-安装包)

## 许可

EchoPane 源码采用 MIT 许可证。第三方组件和预览素材采用各自的许可。 [项目许可证](LICENSE) [第三方许可与素材来源](THIRD_PARTY_NOTICES.md)
