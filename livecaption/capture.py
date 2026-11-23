"""Capture PCM only from the selected Windows process tree."""
import ctypes
import math
import os
import time
from collections import Counter
from ctypes import wintypes

import numpy as np
import psutil
import soxr
from proctap._native import ProcessLoopback


PLAYER_NAMES = {
    "chrome.exe": "Google Chrome",
    "msedge.exe": "Microsoft Edge",
    "firefox.exe": "Firefox",
    "brave.exe": "Brave",
    "opera.exe": "Opera",
    "vlc.exe": "VLC",
    "mpv.exe": "mpv",
    "potplayermini64.exe": "PotPlayer",
}


def window_sources():
    user = ctypes.windll.user32
    found = {}
    own_pid = os.getpid()
    callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user.EnumWindows.argtypes = [callback, wintypes.LPARAM]
    user.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    user.IsWindowVisible.argtypes = [wintypes.HWND]
    user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]

    @callback
    def visit(hwnd, _):
        size = user.GetWindowTextLengthW(hwnd)
        if size > 0 and user.IsWindowVisible(hwnd):
            pid = wintypes.DWORD()
            user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if not pid.value or pid.value == own_pid or pid.value in found:
                return True
            title = ctypes.create_unicode_buffer(size + 1)
            user.GetWindowTextW(hwnd, title, size + 1)
            try:
                process = psutil.Process(pid.value)
                name = process.name()
                player = PLAYER_NAMES.get(name.casefold(), name.removesuffix(".exe"))
                label = f"{player} · {title.value[:72]}"
                found[process.pid] = (label, process)
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        return True

    user.EnumWindows(visit, 0)
    counts = Counter(label for label, _ in found.values())
    labels = ((f"{label} [{process.pid}]" if counts[label] > 1 else label, process)
              for label, process in found.values())
    return dict(sorted(labels, key=lambda entry: entry[0].casefold()))


def pcm_level(pcm):
    if not pcm:
        return 0.0
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32)
    power = float(samples @ samples) / (len(samples) * 32768**2)
    db = 10 * math.log10(max(power, 1e-8))
    return max(0.0, min(1.0, (db + 64) / 60))


class AudioSource:
    def __init__(self, process):
        if not process.is_running():
            raise RuntimeError("所选程序已关闭，请刷新声音来源。")
        self.process = process
        self.next_check = 0
        self.tap = ProcessLoopback(process.pid)
        if not self.tap.is_process_specific():
            raise RuntimeError("当前系统无法隔离此程序的声音。")
        fmt = self.tap.get_format()
        self.channels = fmt["channels"]
        types = {16: "<i2", 32: "<f4"}
        self.dtype = types.get(fmt["bits_per_sample"])
        if self.dtype is None or self.channels < 1:
            raise RuntimeError("当前采音格式不受支持。")
        self.max_buffer = fmt["sample_rate"] * fmt["block_align"] * 2
        self.converter = soxr.ResampleStream(fmt["sample_rate"], 16000, 1, dtype="float32")

    def __enter__(self):
        self.tap.start()
        return self

    def __exit__(self, *exc):
        self.tap.stop()

    def read(self, last=False):
        now = time.monotonic()
        if not last and now >= self.next_check:
            if not self.process.is_running():
                raise RuntimeError("声音来源已关闭。")
            self.next_check = now + 0.5
        # ProcTap's native read fetches one WASAPI packet. Drain all pending
        # packets to keep up when the Windows audio engine runs at 10 ms.
        data = bytearray()
        while chunk := self.tap.read():
            data.extend(chunk)
            if len(data) > self.max_buffer:
                raise RuntimeError("采音积压超过两秒，请重新开始。")
        if not data and not last:
            return b""
        frames = np.frombuffer(data, dtype=self.dtype).reshape(-1, self.channels)
        mono = frames.mean(axis=1, dtype=np.float32)
        if self.dtype == "<i2":
            mono /= 32768
        pcm = self.converter.resample_chunk(mono, last=last)
        return np.clip(np.rint(pcm * 32768), -32768, 32767).astype("<i2").tobytes()

