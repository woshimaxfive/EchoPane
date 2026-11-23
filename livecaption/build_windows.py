"""Build the Windows x64 installer from the live-caption source."""

import sys
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path

import lief
from cx_Freeze import Executable, setup
from cx_Freeze.command.build_exe import build_exe
from freeze_core.winmsvcr import MSVC_FILES

from screen_ocr import MODEL_HASHES


SOURCE = Path(__file__).resolve().parent
LOCAL = SOURCE.parent / ".local"
BUILD_DIR = LOCAL / "windows-build"
VERSION = "0.2.16"
LIBRARY_SOURCES = (
    ("soxr", "soxr-1.1.0.tar.gz", "9f228ae21c78fa9359ca98d8a5e8e91f30639e438e574133dace62c5b5309e44"),
    ("shapely", "geos-3.14.1.tar.bz2", "3c20919cda9a505db07b5216baa980bacdaa0702da715b43f176fb07eff7e716"),
)
VC_RUNTIME_FILES = (
    ("ECHOPANE_MSVC_CPP", "msvcp140.dll"),
    ("ECHOPANE_MSVC_CPP_AUX", "msvcp140_1.dll"),
    ("ECHOPANE_MSVC_CORE", "vcruntime140.dll"),
    ("ECHOPANE_MSVC_SUPPORT", "vcruntime140_1.dll"),
)


class BuildWithSystemRuntime(build_exe):
    def run(self):
        super().run()
        payload = Path(self.build_exe)
        # Use the system runtime for the wheels that carry renamed copies of MSVCP140.
        for package, patterns in (
            ("numpy", ("lib/numpy/_core/_multiarray_umath*.pyd", "lib/numpy/fft/_pocketfft_umath*.pyd")),
            ("shapely", ("lib/shapely.libs/geos-*.dll", "lib/shapely.libs/geos_c-*.dll")),
        ):
            vendor_runtime, = (payload / "lib" / f"{package}.libs").glob("msvcp140-*.dll")
            for pattern in patterns:
                extension, = payload.glob(pattern)
                use_system_msvc(extension, vendor_runtime.name)
            vendor_runtime.unlink()

        # OCR processes still images. The OpenCV video plug-in is not part of this payload.
        for plugin in payload.rglob("opencv_videoio_ffmpeg*.dll"):
            plugin.unlink()
        unexpected = [file.name for file in payload.rglob("*.dll")
                      if file.name.lower() in MSVC_FILES or file.name.lower().startswith(("msvcp140-", "vcruntime140-"))]
        if unexpected:
            raise RuntimeError(f"安装包中仍有 Microsoft Visual C++ 运行库：{', '.join(unexpected)}")


def use_system_msvc(file, vendor_name):
    binary = lief.PE.parse(str(file))
    dependency = binary.get_import(vendor_name)
    if dependency is None or binary.get_import("msvcp140.dll") or binary.has_signatures:
        raise RuntimeError(f"运行库引用与预期不符：{file.name}")
    dependency.name = "msvcp140.dll"
    options = lief.PE.Builder.config_t()
    options.imports = True
    updated = file.with_suffix(".tmp")
    try:
        binary.write(str(updated), options)
        rewritten = lief.PE.parse(str(updated))
        if not rewritten.get_import("msvcp140.dll") or rewritten.get_import(vendor_name):
            raise RuntimeError(f"未能更新运行库引用：{file.name}")
        updated.replace(file)
    finally:
        updated.unlink(missing_ok=True)


def runtime_installer_checks():
    # A version just below 14.44.35211.0 avoids an exact-version language match.
    minimum_version = "14.44.35210.65535"
    condition = " AND ".join(name for name, _ in VC_RUNTIME_FILES)
    # cx_Freeze schedules AppSearch at 400 in both MSI sequences.
    check = ("EchoPaneNeedsVCRuntime", f"NOT Installed AND NOT ({condition})", 403)
    message = ("EchoPane needs the Microsoft Visual C++ x64 Runtime. Install the current runtime from "
               "https://aka.ms/vc14/vc_redist.x64.exe, then run this installer again.")
    return {
        "AppSearch": [(name, name) for name, _ in VC_RUNTIME_FILES],
        "DrLocator": [(name, None, "[System64Folder]", 0) for name, _ in VC_RUNTIME_FILES],
        "Signature": [(name, filename, minimum_version, None, None, None, None, None, None)
                      for name, filename in VC_RUNTIME_FILES],
        "CustomAction": [(check[0], 19, None, message)],
        "InstallUISequence": [check],
        "InstallExecuteSequence": [check],
    }


def license_files():
    requirements = (SOURCE / "requirements.txt").read_text(encoding="utf-8")
    packages = [line.partition("==")[0] for line in requirements.splitlines() if line]
    files = [
        (SOURCE.parent / "LICENSE", "LICENSE"),
        (SOURCE.parent / "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md"),
        (Path(sys.base_prefix) / "LICENSE.txt", "licenses/Python/LICENSE.txt"),
        (SOURCE / "licenses", "licenses/runtime"),
    ]
    for library, name, digest in LIBRARY_SOURCES:
        source = BUILD_DIR / "sources" / name
        if not source.is_file() or sha256(source.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"缺少已校验的 {library} 对应源码。请按 livecaption/README.md 下载到 {source}")
        files.append((source, Path("licenses", library, "source", name)))
    for name in (*packages, "cx-Freeze", "freeze-core"):
        package = distribution(name)
        for record in package.files or ():
            info, *parts = record.parts
            if info.endswith(".dist-info") and parts and parts[0].casefold().startswith(
                ("license", "copying", "notice")
            ):
                files.append((package.locate_file(record), Path("licenses", name, *parts)))
    for name, module, notices in (
        ("onnxruntime", "onnxruntime", ("LICENSE", "ThirdPartyNotices.txt")),
        ("opencv-python-headless", "cv2", ("LICENSE.txt", "LICENSE-3RD-PARTY.txt")),
    ):
        for filename in notices:
            files.append((distribution(name).locate_file(Path(module, filename)), Path("licenses", name, filename)))
    return files


def ocr_files():
    package = distribution("rapidocr")
    resources = ["config.yaml", "default_models.yaml", *(f"models/{name}" for name in MODEL_HASHES)]
    files = []
    for resource in resources:
        source = package.locate_file(Path("rapidocr", resource))
        if digest := MODEL_HASHES.get(Path(resource).name):
            if not source.is_file() or sha256(source.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"RapidOCR 模型校验失败：{source}")
        files.append((source, Path("lib/rapidocr", resource)))
    shapely_libs = distribution("shapely").locate_file("shapely.libs")
    files.append((shapely_libs, "lib/shapely.libs"))
    return files


BUILD_DIR.mkdir(parents=True, exist_ok=True)

setup(
    name="EchoPane",
    version=VERSION,
    description="EchoPane captions and screen translation",
    author="EchoPane",
    cmdclass={"build_exe": BuildWithSystemRuntime},
    executables=[Executable(
        str(SOURCE / "app.py"),
        base="gui",
        icon=str(SOURCE / "assets" / "echopane.ico"),
        target_name="EchoPane.exe",
        shortcut_name="EchoPane",
        shortcut_dir="ProgramMenuFolder",
    )],
    options={
        "build": {"build_base": str(BUILD_DIR / "build" / VERSION)},
        "egg_info": {"egg_base": str(BUILD_DIR)},
        "build_exe": {
            "include_msvcr": False,
            "includes": ["rapidocr.inference_engine.onnxruntime.main"],
            "include_files": [
                (SOURCE / "README.md", "README.md"), (SOURCE / "assets", "assets"), *license_files(), *ocr_files(),
            ],
            "replace_paths": [("*", ".")],
        },
        "bdist_msi": {
            "all_users": False,
            "data": runtime_installer_checks(),
            "bdist_dir": str(BUILD_DIR / "msi-work"),
            "dist_dir": str(LOCAL / "windows-package"),
            "initial_target_dir": r"[LocalAppDataFolder]Programs\EchoPane",
            "launch_on_finish": True,
            "output_name": f"EchoPane-{VERSION}-win-x64.msi",
            "upgrade_code": "{AE019BF8-43D1-46A5-9FC4-6171A7F61E81}",
        },
    },
)
