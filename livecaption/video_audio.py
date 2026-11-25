"""Decode a local audio track with FFmpeg and keep bounded recognition blocks."""

import json
import math
import os
import subprocess
import sys
from contextlib import closing
from dataclasses import dataclass
from itertools import chain
from pathlib import Path


RATE = 16_000
BYTES_PER_MS = RATE * 2 // 1000
BLOCK_MS = 60_000
CONTEXT_MS = 1_200
MEDIA_EXTENSIONS = frozenset((".mp4", ".m4v", ".mov", ".mkv", ".avi", ".wmv", ".webm", ".m4a", ".wav", ".mp3"))


class MediaError(RuntimeError):
    """A local decode error suitable for the video subtitle page."""


@dataclass(frozen=True)
class AudioBlock:
    start: int
    end: int
    offset: int
    pcm: bytes


def decoder(name):
    if getattr(sys, "frozen", False):
        directory = Path(sys.executable).resolve().parent / "ffmpeg"
    else:
        default = Path(__file__).resolve().parents[1] / ".local/windows-build/ffmpeg"
        directory = Path(os.environ.get("ECHOPANE_FFMPEG_DIR") or default).resolve()
    executable = directory / f"{name}.exe"
    if not executable.is_file():
        raise MediaError("视频解码组件缺失，请重新安装 EchoPane，或按源码文档准备 FFmpeg。")
    return str(executable)


def audio_duration(path):
    path = Path(path).resolve(strict=True)
    if not path.is_file() or path.suffix.casefold() not in MEDIA_EXTENSIONS:
        raise MediaError("请选择本机的视频或音频文件。")
    try:
        probe = subprocess.run(
            [decoder("ffprobe"), "-v", "error", "-protocol_whitelist", "file,pipe", "-select_streams", "a:0",
             "-show_entries", "stream=index:format=duration", "-of", "json", str(path)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW, timeout=15,
        )
    except subprocess.TimeoutExpired:
        raise MediaError("读取媒体信息超时，请检查源文件。") from None
    if probe.returncode:
        raise MediaError("无法打开此媒体文件，请检查文件或转为 MP4 后重试。")
    try:
        info = json.loads(probe.stdout)
        if not info.get("streams"):
            raise MediaError("此文件没有可读音轨。")
        duration = float(info.get("format", {}).get("duration", "nan"))
        return round(duration * 1_000) if math.isfinite(duration) and duration > 0 else 0
    except (ValueError, TypeError, AttributeError, OverflowError):
        return 0


def pcm_chunks(path, stop):
    if stop.is_set():
        return
    # Shift the complete presentation to start at zero, preserving any
    # relative audio delay. Resampling pads real gaps and trims overlaps.
    arguments = [decoder("ffmpeg"), "-hide_banner", "-nostdin", "-v", "error", "-xerror", "-copyts", "-start_at_zero",
                 "-protocol_whitelist", "file,pipe", "-i", str(path), "-map", "0:a:0", "-vn", "-sn", "-dn",
                 "-af", f"aresample={RATE}:async=1:first_pts=0", "-ac", "1", "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"]
    with subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          creationflags=subprocess.CREATE_NO_WINDOW) as process:
        try:
            while not stop.is_set() and (pcm := process.stdout.read(65_536)):
                yield pcm
            if not stop.is_set() and process.wait(timeout=5):
                raise MediaError("无法解码此音轨，试试转为带 AAC 音轨的 MP4。")
        except subprocess.TimeoutExpired:
            raise MediaError("音轨读取超时，请检查源文件。") from None
        finally:
            if process.poll() is None:
                process.kill()


def audio_blocks(path, stop, *, start_ms=0):
    """Keep bounded audio in memory and assign each timestamp to one block."""
    size = BLOCK_MS * BYTES_PER_MS
    context = CONTEXT_MS * BYTES_PER_MS
    start = start_ms * BYTES_PER_MS
    buffer_start = max(0, start - context)
    pending = bytearray()
    received = 0
    with closing(pcm_chunks(path, stop)) as chunks:
        for pcm in chain(chunks, (None,)):
            if stop.is_set():
                return
            if pcm is not None:
                pending.extend(pcm[max(0, buffer_start - received):])
                received += len(pcm)
            while start < received and (pcm is None or received >= start + size + context):
                end = min(start + size, received)
                clip_end = min(received, end + context) - buffer_start
                yield AudioBlock(start // BYTES_PER_MS, (end + BYTES_PER_MS - 1) // BYTES_PER_MS,
                                 buffer_start // BYTES_PER_MS, bytes(pending[:clip_end]))
                if stop.is_set():
                    return
                start = end
                keep_from = max(buffer_start, start - context)
                del pending[:keep_from - buffer_start]
                buffer_start = keep_from
