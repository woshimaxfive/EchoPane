# EchoPane

EchoPane 是面向 Windows 的实时字幕和屏幕翻译工具。选择播放窗口或 Windows 默认播放设备上的系统声音，就能在桌面浮窗里看原文、中文字幕或双语字幕。回看支持按场次查找关键词，字幕可保存在本机并导出 TXT 或 SRT。

## 开始使用

1. 获取 Windows 11 x64 的 EchoPane MSI 安装包。双击 MSI 安装，再从开始菜单打开 EchoPane。
2. 在「设置」填入自己的百炼北京地域 API Key。使用指定业务空间时，在「高级设置」填入空间 ID。
3. 在「实时字幕」选择播放窗口或「全系统声音（默认输出）」，点击「开始字幕」。在「字幕外观」可预先选择仅译文、仅原文或双语。
4. 在「屏幕翻译」框选文字区域。识别在本机完成，可以修改原文，再点击「翻译」查看中文译文。
5. 在「字幕文件」导入 SRT 或 WebVTT，沿用百炼 Key 翻译，按原时间轴导出译文或双语字幕。
6. 在「网页字幕」用随包扩展连接 Chrome 或 Edge 的视频标签页，将播放器已开启的 HTML5 字幕翻译到桌面浮窗。 [安装扩展与支持范围](livecaption/README.md#网页已有字幕)
7. 在「设置 → 术语词表」保存常用人名、地名和术语的指定译法。 [词表使用说明](livecaption/README.md#术语词表)
8. 在「视频字幕」导入本地视频，用已有百炼 Key 生成原文或双语字幕，按原视频时间码导出 SRT 或 WebVTT。 [视频字幕用法](livecaption/README.md#本地视频生成字幕)
9. 在「实时字幕」选择「本地原文」，可通过魔搭下载约 229 MiB 的模型，也可直接导入模型包。模型就绪后可断网识别播放声音，使用同一个浮窗和回看。 [本地原文用法](livecaption/README.md#本地原文字幕)

如果安装程序提示缺少 Microsoft Visual C++ x64 运行库，请先装微软提供的运行库，再运行 EchoPane MSI。 [微软官方下载](https://aka.ms/vc14/vc_redist.x64.exe)

实时翻译需要联网。所选音源的音频会发往阿里云百炼，使用量计入自己的百炼账户。浏览器共用进程时，同一进程树中其他标签页的声音也可能被采集。 [使用与数据保存说明](livecaption/README.md)

## 从源码运行和构建

使用带 Tk 的 Python 3.12 x64，运行 `livecaption/start.cmd`。构建 MSI 使用 Python 3.14 x64。 [完整构建步骤](livecaption/README.md#构建-windows-安装包)

## 许可

EchoPane 源码采用 MIT 许可证。第三方组件和预览素材采用各自的许可。 [项目许可证](LICENSE) [第三方许可与素材来源](THIRD_PARTY_NOTICES.md)
