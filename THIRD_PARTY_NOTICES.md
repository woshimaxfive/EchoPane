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
| [cx-Freeze 8.7.4](https://pypi.org/project/cx-Freeze/8.7.4/) 和 [freeze-core 0.8.1](https://pypi.org/project/freeze-core/0.8.1/) | PSF-2.0、MIT | `licenses/cx-Freeze/`、`licenses/freeze-core/` |

NumPy 和 SciPy 的 Windows wheel 附带 OpenBLAS、LAPACK 和使用 GCC Runtime Library Exception 3.1 的 GCC 运行库代码。声明见各 wheel 自带的 `LICENSE.txt`，相同文本随安装包附带。SQLite 的公有领域声明见 SQLite 项目说明。 [SQLite 版权说明](https://www.sqlite.org/copyright.html)

## SoXR 对应源码

安装包在 `licenses/soxr/source/soxr-1.1.0.tar.gz` 提供 SoXR 对应源码和构建文件。也可从 PyPI 下载同一版本的源码发行包。需修改和测试该库时，退出 EchoPane，按源码内的 `BUILDING.md` 构建兼容当前 CPython 与 Windows x64 的 wheel，再用其中的 `soxr` 模块替换安装目录下的 `lib/soxr/`。 [PyPI 源码下载](https://pypi.org/project/soxr/1.1.0/#files) [LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)

## Microsoft Visual C++ 运行库

EchoPane 使用系统中的 Microsoft Visual C++ x64 运行库，最低版本为 14.44.35211.0。构建时会将 NumPy 两个扩展中的 DLL 引用改为系统文件名，并从 Windows MSI 载荷移除 wheel 内附的 Microsoft DLL。缺少运行库时，可先从微软安装。 [Microsoft 运行库说明与下载](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)

## 字幕示例照片

`livecaption/assets/caption-preview.png` 取自美国国家公园管理局的 Point Reyes National Seashore 照片。档案页面将权利状态标记为公有领域。 [NPS 照片档案](https://npgallery.nps.gov/AssetDetail/f1a8781f-9110-4676-81b0-3f88b658b8ca)
