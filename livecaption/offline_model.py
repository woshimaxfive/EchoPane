"""Download or import the pinned SenseVoiceSmall model files."""

import msvcrt
import sys
from contextlib import contextmanager
from hashlib import file_digest
from http.client import HTTPException
from pathlib import Path
from shutil import copyfile
from ssl import SSLError
from tempfile import TemporaryDirectory
from urllib.error import URLError
from urllib.request import Request, urlopen
from zipfile import BadZipFile, ZipFile
from zlib import error as CompressionError

from preferences import appearance_path


MODEL_NAME = "SenseVoiceSmall"
MODEL_RELEASE = "sensevoice-int8-2024-07-17"
UPSTREAM = (
    "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/"
    "resolve/2365baeacb507f821a0c8120fcee3d484dba7a07/"
)
MODELSCOPE = (
    "https://modelscope.cn/api/v1/models/burgess123/sherpa-onnx-SenseVoice-Small-onnx/"
    "repo?Revision=463f5fb39a72fe2d85039a9b9fb87309271721ff&FilePath="
)
SILERO_VAD = ("silero_vad.onnx", (), 643_854,
              "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
MODEL_FILES = (
    ("model.int8.onnx", (MODELSCOPE + "model.int8.onnx", UPSTREAM + "model.int8.onnx"), 239_233_841,
     "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
    ("tokens.txt", (MODELSCOPE + "tokens.txt", UPSTREAM + "tokens.txt"), 315_894,
     "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"),
    SILERO_VAD,
)
MODEL_BYTES = sum(size for _, _, size, _ in MODEL_FILES)
MODEL_MIB = round(MODEL_BYTES / 1024**2)


class ModelContentError(RuntimeError):
    pass


def model_path():
    return appearance_path().parent / "models" / MODEL_RELEASE


def model_ready():
    directory = model_path()
    try:
        return all((directory / name).stat().st_size == size for name, _, size, _ in MODEL_FILES)
    except OSError:
        return False


def matches(path, size, digest):
    try:
        if path.stat().st_size != size:
            return False
        with path.open("rb") as existing:
            return file_digest(existing, "sha256").hexdigest() == digest
    except OSError:
        return False


def checked_model(directory=None):
    if directory is None:
        directory = model_path()
    if not all(matches(directory / name, size, digest) for name, _, size, digest in MODEL_FILES):
        raise ModelContentError("本地模型缺失或校验失败，请下载、修复或导入模型。")
    return directory


@contextmanager
def install_lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".install.lock").open("a+b") as lock:
        lock.seek(0)
        try:
            msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as exc:
            raise RuntimeError("另一个 EchoPane 窗口正在安装模型，请稍后再试。") from exc
        try:
            yield
        finally:
            msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)


def write_stream(source, staged, size, offset, stop, progress):
    with staged.open("ab" if offset else "wb") as pending:
        received = offset
        while not stop.is_set() and (chunk := source.read(min(512 * 1024, size - received + 1))):
            received += len(chunk)
            if received > size:
                raise ModelContentError("模型文件大小与发布记录不符。")
            pending.write(chunk)
            progress(received)


def fetch_file(partial, sources, size, digest, stop, progress):
    if matches(partial, size, digest):
        return
    for url in sources:
        if stop.is_set():
            return
        offset = partial.stat().st_size if partial.is_file() else 0
        if offset >= size:
            partial.unlink()
            offset = 0
        headers = {"Range": f"bytes={offset}-{size - 1}"} if offset else {}
        try:
            with urlopen(Request(url, headers=headers), timeout=15) as response:
                if response.status == 200:
                    offset = 0
                elif response.status != 206 or response.headers.get("Content-Range") != f"bytes {offset}-{size - 1}/{size}":
                    continue
                progress(offset)
                if stop.is_set():
                    return
                write_stream(response, partial, size, offset, stop, progress)
        except ModelContentError:
            partial.unlink(missing_ok=True)
            continue
        except (URLError, HTTPException, ConnectionError, TimeoutError, SSLError):
            continue
        if stop.is_set() or matches(partial, size, digest):
            return
    if not stop.is_set():
        raise RuntimeError("模型下载未完成，可重试续传或导入模型包。")


def download_model(stop, progress):
    directory = model_path()
    bundle = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent / "assets"
    completed = 0
    with install_lock(directory):
        for name, sources, size, digest in MODEL_FILES:
            if stop.is_set():
                return
            destination = directory / name
            if not matches(destination, size, digest):
                partial = directory / f"{name}.part"
                if sources:
                    fetch_file(partial, sources, size, digest, stop, lambda count: progress(completed + count))
                else:
                    if not matches(bundle / name, size, digest):
                        raise ModelContentError("附带的语音检测文件校验失败，请导入模型包或重装 EchoPane。")
                    copyfile(bundle / name, partial)
                    if not matches(partial, size, digest):
                        raise ModelContentError("复制语音检测文件失败，请重试。")
                if stop.is_set():
                    return
                partial.replace(destination)
            completed += size
            progress(completed)


def import_model_package(package, stop, progress):
    directory = model_path()
    with install_lock(directory), TemporaryDirectory(dir=directory, prefix="import-") as temporary:
        staging = Path(temporary)
        completed = 0
        try:
            with ZipFile(package) as archive:
                names = archive.namelist()
                for name, _, size, _ in MODEL_FILES:
                    if stop.is_set():
                        return
                    if names.count(name) != 1:
                        raise ModelContentError("模型包缺少所需文件或包含重复文件。")
                    member = archive.getinfo(name)
                    if member.file_size != size or member.flag_bits & 1:
                        raise ModelContentError("模型包文件大小或格式不符。")
                    with archive.open(member) as source:
                        write_stream(source, staging / name, size, 0, stop, lambda count: progress(completed + count))
                    completed += size
        except (BadZipFile, NotImplementedError, EOFError, CompressionError) as exc:
            raise ModelContentError("模型包无法读取，请检查 ZIP 文件。") from exc
        if stop.is_set():
            return
        checked_model(staging)
        for name, _, size, digest in MODEL_FILES:
            destination = directory / name
            if not matches(destination, size, digest):
                (staging / name).replace(destination)
            (directory / f"{name}.part").unlink(missing_ok=True)
