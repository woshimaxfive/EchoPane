"""Record a short translated voice preview and play it through Windows."""

import ctypes as ct
import io
import queue
import threading
import tkinter as tk
import wave
from ctypes import wintypes as win
from tkinter import ttk
from winsound import SND_ASYNC, SND_MEMORY, SND_NODEFAULT

import theme
from cloud import VOICE_RECORD_SECONDS, VOICE_SAMPLE_RATE
from session import LiveSession


LANGUAGES = {"英语": "en", "中文": "zh", "日语": "ja", "韩语": "ko"}
PCM_BYTES_PER_SECOND = VOICE_SAMPLE_RATE * 2
MAX_VOICE_BYTES = PCM_BYTES_PER_SECOND * 30

play_sound = ct.WinDLL("winmm").PlaySoundW
play_sound.argtypes = [ct.c_void_p, win.HMODULE, win.DWORD]
play_sound.restype = win.BOOL


def record_translation(open_source, key, workspace, stop, events, language):
    pcm = bytearray()
    captions = {}

    def emit(kind, data):
        if kind == "audio":
            if len(pcm) + len(data) > MAX_VOICE_BYTES:
                raise RuntimeError("译音太长，请缩短录音后重试。")
            pcm.extend(data)
        elif kind == "caption" and data.final:
            captions[data.ident] = data.text
        elif kind in ("status", "capture_finished"):
            events.put((kind, None))
        elif kind in ("end", "content_blocked"):
            events.put(("end", (data, pcm, "\n".join(captions.values()))))

    LiveSession.run(open_source, key, workspace, stop, emit, voice_language=language)


class VoiceAudition(tk.Toplevel):
    def __init__(self, parent, open_source, key, workspace, *, on_close):
        super().__init__(parent, bg=theme.BACKGROUND)
        self.title("译音试听")
        self.transient(parent)
        self.resizable(False, False)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.bind("<Escape>", lambda _event: self.close())
        self.open_source = open_source
        self.configuration = key, workspace
        self.on_close = on_close
        self.events = queue.SimpleQueue()
        self.stop_flag = None
        self.closing = False
        self.pcm = b""
        self.playback_buffer = None
        self.playback_timer = None

        content = ttk.Frame(self, padding=18)
        content.pack(fill="both", expand=True)
        scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        wrap = min(round(350 * scale), self.winfo_screenwidth() - 92)

        selector = ttk.Frame(content)
        selector.pack(fill="x")
        ttk.Label(selector, text="译音语言").pack(side="left", padx=(0, 12))
        self.language = ttk.Combobox(selector, state="readonly", values=tuple(LANGUAGES), width=10)
        self.language.current(0)
        self.language.pack(side="left")
        ttk.Label(content, text=f"用所选麦克风录一句，最长 {VOICE_RECORD_SECONDS} 秒。音频发往百炼并按用量计费。",
                  style="Hint.TLabel", wraplength=wrap).pack(fill="x", pady=(10, 12))
        panel = ttk.Frame(content, padding=12, style="Panel.TFrame")
        panel.pack(fill="x")
        self.status = ttk.Label(panel, text="点击录音，等提示后说话。", style="PanelHint.TLabel", wraplength=wrap)
        self.status.pack(fill="x")
        self.translation = ttk.Label(panel, style="Panel.TLabel", wraplength=wrap)
        self.translation.pack(fill="x", pady=(4, 0))

        actions = ttk.Frame(content)
        actions.pack(fill="x", pady=(14, 0))
        self.record_button = ttk.Button(actions, style="Primary.TButton", command=self.record)
        self.record_button.pack(side="left", padx=(0, 8))
        self.play_button = ttk.Button(actions, style="Outline.TButton", command=self.toggle_playback)
        self.play_button.pack(side="left")
        self.update_controls()
        self.update_idletasks()
        self.grab_set()
        self.record_button.focus_set()

    def update_controls(self):
        active = self.stop_flag is not None
        playing = self.playback_buffer is not None
        ending = active and self.stop_flag.is_set()
        self.language.configure(state="disabled" if active or playing else "readonly")
        self.record_button.configure(text="结束录音" if active else "录音",
                                     state="disabled" if ending or playing else "normal")
        self.play_button.configure(text="停止播放" if playing else "播放译音",
                                   state="normal" if self.pcm and not active else "disabled")

    def record(self):
        if self.stop_flag is not None:
            self.stop_flag.set()
            self.status.configure(text="正在生成译音…")
            self.update_controls()
            return
        self.stop_flag = threading.Event()
        self.pcm = b""
        self.translation.configure(text="")
        self.status.configure(text="正在连接百炼…")
        self.update_controls()
        worker = threading.Thread(
            target=record_translation,
            args=(self.open_source, *self.configuration, self.stop_flag, self.events, LANGUAGES[self.language.get()]),
            daemon=True,
        )
        try:
            worker.start()
        except RuntimeError:
            self.finish_recording("无法开始录音，请重试。", b"", "")
        else:
            self.after(35, self.poll)

    def poll(self):
        while True:
            try:
                kind, data = self.events.get_nowait()
            except queue.Empty:
                self.after(35, self.poll)
                return
            if kind == "end":
                self.finish_recording(*data)
                return
            if not self.closing:
                if kind == "status" and not self.stop_flag.is_set():
                    self.status.configure(text="正在录音，说完后点击结束录音。")
                elif kind == "capture_finished":
                    self.status.configure(text="正在生成译音…")
                    self.update_controls()

    def finish_recording(self, error, pcm, text):
        self.stop_flag = None
        if self.closing:
            self.close()
            return
        if error or len(pcm) % 2:
            self.status.configure(text=error or "译音数据不完整，请重试。")
        elif not pcm:
            self.status.configure(text="没有收到译音。请检查麦克风，等到显示「正在录音」再说话。")
        else:
            self.pcm = pcm
            self.translation.configure(text=text)
            self.status.configure(text="译音已就绪，可从 Windows 默认输出播放。")
        self.update_controls()

    def toggle_playback(self):
        if self.playback_buffer is not None:
            self.stop_playback()
            return
        data = io.BytesIO()
        with wave.open(data, "wb") as wav:
            wav.setparams((1, 2, VOICE_SAMPLE_RATE, 0, "NONE", ""))
            wav.writeframes(self.pcm)
        # PlaySound uses this memory until playback has stopped.
        buffer = ct.create_string_buffer(data.getvalue())
        if not play_sound(buffer, None, SND_MEMORY | SND_ASYNC | SND_NODEFAULT):
            self.status.configure(text="无法播放译音，请检查 Windows 默认输出设备。")
            return
        self.playback_buffer = buffer
        self.status.configure(text="正在播放译音…")
        self.update_controls()
        duration_ms = round(1000 * len(self.pcm) / PCM_BYTES_PER_SECOND)
        self.playback_timer = self.after(duration_ms + 400, self.stop_playback)

    def stop_playback(self):
        if self.playback_buffer is not None:
            self.after_cancel(self.playback_timer)
            play_sound(None, None, 0)
            self.playback_buffer = None
            self.playback_timer = None
            self.status.configure(text="译音已就绪，可再次播放。")
            self.update_controls()

    def close(self):
        if self.stop_flag is not None:
            self.closing = True
            self.stop_flag.set()
            self.status.configure(text="正在结束试听…")
            self.update_controls()
            return
        self.stop_playback()
        self.destroy()
        self.on_close()
