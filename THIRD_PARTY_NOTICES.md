# 第三方许可与素材来源

EchoPane 源码采用 [MIT 许可证](LICENSE)。安装目录的 `licenses/` 包含以下组件的许可原文和版权声明。

| 组件 | 许可或声明 | 安装目录内路径 |
| --- | --- | --- |
| [CPython 3.14.10](https://www.python.org/downloads/release/python-31410/) | PSF 许可证及随附组件声明 | `licenses/Python/LICENSE.txt` |
| Tcl、Tk、OpenSSL | Tcl/Tk 使用各自的许可，OpenSSL 3 使用 Apache-2.0 | `licenses/runtime/` |
| [NumPy 2.5.5](https://pypi.org/project/numpy/2.5.5/) | BSD-3-Clause 及随附组件许可 | `licenses/numpy/` |
| [SciPy 1.18.1](https://pypi.org/project/scipy/1.18.1/) | BSD-3-Clause 及随附组件许可 | `licenses/scipy/` |
| [ProcTap 1.1.1](https://pypi.org/project/proc-tap/1.1.1/) | MIT | `licenses/proc-tap/` |
| [psutil 7.2.2](https://pypi.org/project/psutil/7.2.2/) | BSD-3-Clause | `licenses/psutil/` |
| [Python-SoXR 1.1.0](https://pypi.org/project/soxr/1.1.0/) | LGPL-2.1-or-later，附有 libsoxr 和 PFFFT 的声明 | `licenses/soxr/` |
| [websockets 16.1.1](https://pypi.org/project/websockets/16.1.1/) | BSD-3-Clause | `licenses/websockets/` |
| [webvtt-py 0.8.0](https://pypi.org/project/webvtt-py/0.8.0/) | MIT | `licenses/webvtt-py/` |
| [FFmpeg 9.1](https://ffmpeg.org/download.html#release_9.1) | LGPL-2.1-or-later | `licenses/ffmpeg/` |
| [RapidOCR 3.10.0](https://pypi.org/project/rapidocr/3.10.0/) 及随附 PaddleOCR PP-OCRv6 模型 | Apache-2.0，模型出处与哈希在 `MODEL_LICENSES.md` | `licenses/rapidocr/` |
| [ONNX Runtime 1.32.0](https://pypi.org/project/onnxruntime/1.32.0/) | MIT 及随附组件声明 | `licenses/onnxruntime/` |
| [sherpa-onnx 2.0.2](https://pypi.org/project/sherpa-onnx/2.0.2/) | Apache-2.0 | `licenses/sherpa-onnx/` |
| [OpenCV Python Headless 5.1.0.95](https://pypi.org/project/opencv-python-headless/5.1.0.95/) | MIT（Python 打包脚本）、Apache-2.0（OpenCV）及随附组件声明 | `licenses/opencv-python-headless/` |
| [Shapely 2.2.0](https://pypi.org/project/shapely/2.2.0/) 及 [GEOS 3.14.1](https://libgeos.org/usage/download/) | BSD-3-Clause（Shapely）、LGPL-2.1（GEOS）及随附组件声明 | `licenses/shapely/` |
| [Pillow 13.0.0](https://pypi.org/project/pillow/13.0.0/) | HPND 及随附组件声明 | `licenses/pillow/` |
| [cx-Freeze 8.7.4](https://pypi.org/project/cx-Freeze/8.7.4/) 和 [freeze-core 0.8.1](https://pypi.org/project/freeze-core/0.8.1/) | PSF-2.0、MIT | `licenses/cx-Freeze/`、`licenses/freeze-core/` |

NumPy 和 SciPy 的 Windows wheel 附带 OpenBLAS、LAPACK 和使用 GCC Runtime Library Exception 3.1 的 GCC 运行库代码。声明见各 wheel 自带的 `LICENSE.txt`，相同文本随安装包附带。SQLite 的公有领域声明见 SQLite 项目说明。 [SQLite 版权说明](https://www.sqlite.org/copyright.html)

OCR 的其余 Python 依赖及其精确版本见 `livecaption/requirements.txt`，许可文件随安装包附带。安装包使用 OpenCV 的静态图像处理能力，构建时移除 FFmpeg 视频插件。

## 按需下载的本地字幕模型

本地原文字幕使用 QwenAudio 与 FunASR 的 SenseVoiceSmall，经 sherpa-onnx 转换为 INT8 ONNX。权重和词表优先从魔搭的固定版本下载，原发布地址备用。Silero VAD 的 16 kHz ONNX 文件随安装包提供。应用核对三份文件的大小和 SHA-256，独立模型包附有 FunASR Model Open Source License v1.1、Silero VAD 的 MIT 许可及来源说明。 [SenseVoiceSmall 模型和许可](https://github.com/QwenAudio/SenseVoice#license) · [sherpa-onnx ONNX 导出](https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html) · [魔搭镜像](https://www.modelscope.cn/models/burgess123/sherpa-onnx-SenseVoice-Small-onnx) · [Silero VAD 许可](https://github.com/snakers4/silero-vad/blob/master/LICENSE)

## SoXR 对应源码

安装包在 `licenses/soxr/source/soxr-1.1.0.tar.gz` 提供 SoXR 对应源码和构建文件。也可从 PyPI 下载同一版本的源码发行包。需修改和测试该库时，退出 EchoPane，按源码内的 `BUILDING.md` 构建兼容当前 CPython 与 Windows x64 的 wheel，再用其中的 `soxr` 模块替换安装目录下的 `lib/soxr/`。 [PyPI 源码下载](https://pypi.org/project/soxr/1.1.0/#files) [LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)

## GEOS 对应源码

安装包在 `licenses/shapely/source/geos-3.14.1.tar.bz2` 提供 GEOS 对应源码。Shapely 通过动态链接使用 `lib/shapely.libs/` 下的 GEOS DLL。要替换库，可退出 EchoPane，按 GEOS 的 CMake 构建步骤生成 ABI 兼容的 x64 DLL。使用 Shapely 2.2.0 的 Windows wheel 打包方式构建或替换时，DLL 文件名及其引用需要匹配 Shapely 模块。 [GEOS 源码与构建](https://libgeos.org/usage/download/) [Shapely 构建说明](https://github.com/shapely/shapely/blob/2.2.0/docs/installation.rst)

## FFmpeg 对应源码

EchoPane 通过独立命令行程序 `ffmpeg/ffmpeg.exe` 和 `ffmpeg/ffprobe.exe` 读取本地音轨。安装包带有 LGPL 2.1 原文、未修改的 `licenses/ffmpeg/source/ffmpeg-9.1.tar.xz` 及对应的 `build_ffmpeg.sh`。MSYS2 UCRT64 构建使用的 GCC 运行库例外和 MinGW-w64 启动代码声明位于 `licenses/ffmpeg/compiler-notices/`。构建仅启用本地文件与管道协议，以及音轨提取需要的组件。可退出 EchoPane，在 MSYS2 UCRT64 下按仓库构建文档重新编译，再替换安装目录 `ffmpeg/` 下的程序。 [FFmpeg 许可](https://ffmpeg.org/legal.html) [对应源码发行包](https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz)

## Microsoft Visual C++ 运行库

EchoPane 使用系统中的 Microsoft Visual C++ x64 运行库，最低版本为 14.44.35211.0。构建时会将 NumPy 扩展及 GEOS DLL 中的私有运行库引用改为系统文件名，并从 Windows MSI 载荷移除 wheel 内附的 Microsoft DLL。缺少运行库时，可先从微软安装。 [Microsoft 运行库说明与下载](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)

## 字幕示例照片

`livecaption/assets/caption-preview.png` 取自美国国家公园管理局的 Point Reyes National Seashore 照片。档案页面将权利状态标记为公有领域。 [NPS 照片档案](https://npgallery.nps.gov/AssetDetail/f1a8781f-9110-4676-81b0-3f88b658b8ca)
