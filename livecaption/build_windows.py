"""Build the Windows x64 installer from the live-caption source."""

import sys
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path

import lief
from cx_Freeze import Executable, setup
from cx_Freeze.command.build_exe import build_exe
from freeze_core.winmsvcr import MSVC_FILES


SOURCE = Path(__file__).resolve().parent
LOCAL = SOURCE.parent / ".local"
BUILD_DIR = LOCAL / "windows-build"
VERSION = "0.2.15"
SOXR_SOURCE = BUILD_DIR / "sources" / "soxr-1.1.0.tar.gz"
SOXR_SOURCE_SHA256 = "9f228ae21c78fa9359ca98d8a5e8e91f30639e438e574133dace62c5b5309e44"
VC_RUNTIME_FILES = (
    ("ECHOPANE_MSVC_CPP", "msvcp140.dll"),
    ("ECHOPANE_MSVC_CORE", "vcruntime140.dll"),
    ("ECHOPANE_MSVC_SUPPORT", "vcruntime140_1.dll"),
)


class BuildWithSystemRuntime(build_exe):
    def run(self):
        super().run()
        payload = Path(self.build_exe)
        numpy_dir = payload / "lib/numpy"
        # The pinned PyPI wheel uses a private name for its copy of MSVCP140.
        vendor_runtime, = (payload / "lib/numpy.libs").glob("msvcp140-*.dll")
        for pattern in ("_core/_multiarray_umath*.pyd", "fft/_pocketfft_umath*.pyd"):
            extension, = numpy_dir.glob(pattern)
            binary = lief.PE.parse(str(extension))
            dependency = binary.get_import(vendor_runtime.name)
            if dependency is None or binary.get_import("msvcp140.dll") or binary.has_signatures:
                raise RuntimeError(f"NumPy 扩展的运行库引用与预期不符：{extension.name}")
            dependency.name = "msvcp140.dll"
            options = lief.PE.Builder.config_t()
            options.imports = True
            updated = extension.with_suffix(".pyd.tmp")
            try:
                binary.write(str(updated), options)
                rewritten = lief.PE.parse(str(updated))
                if not rewritten.get_import("msvcp140.dll") or rewritten.get_import(vendor_runtime.name):
                    raise RuntimeError(f"未能更新 NumPy 扩展的运行库引用：{extension.name}")
                updated.replace(extension)
            finally:
                updated.unlink(missing_ok=True)
        vendor_runtime.unlink()
        unexpected = [file.name for file in payload.rglob("*.dll")
                      if file.name.lower() in MSVC_FILES or file.name.lower().startswith(("msvcp140-", "vcruntime140-"))]
        if unexpected:
            raise RuntimeError(f"安装包中仍有 Microsoft Visual C++ 运行库：{', '.join(unexpected)}")


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
    if not SOXR_SOURCE.is_file() or sha256(SOXR_SOURCE.read_bytes()).hexdigest() != SOXR_SOURCE_SHA256:
        raise RuntimeError(f"缺少已校验的 SoXR 对应源码。请按 livecaption/README.md 下载到 {SOXR_SOURCE}")
    requirements = (SOURCE / "requirements.txt").read_text(encoding="utf-8")
    packages = [line.partition("==")[0] for line in requirements.splitlines() if line]
    files = [
        (SOURCE.parent / "LICENSE", "LICENSE"),
        (SOURCE.parent / "THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md"),
        (Path(sys.base_prefix) / "LICENSE.txt", "licenses/Python/LICENSE.txt"),
        (SOURCE / "licenses", "licenses/runtime"),
        (SOXR_SOURCE, Path("licenses", "soxr", "source", SOXR_SOURCE.name)),
    ]
    for name in (*packages, "cx-Freeze", "freeze-core"):
        package = distribution(name)
        for record in package.files or ():
            info, *parts = record.parts
            if info.endswith(".dist-info") and parts and parts[0].casefold().startswith(
                ("license", "copying", "notice")
            ):
                files.append((package.locate_file(record), Path("licenses", name, *parts)))
    return files


BUILD_DIR.mkdir(parents=True, exist_ok=True)

setup(
    name="EchoPane",
    version=VERSION,
    description="EchoPane live captions",
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
        "build": {"build_base": str(BUILD_DIR / "build")},
        "egg_info": {"egg_base": str(BUILD_DIR)},
        "build_exe": {
            "include_msvcr": False,
            "include_files": [(SOURCE / "README.md", "README.md"), (SOURCE / "assets", "assets"), *license_files()],
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
