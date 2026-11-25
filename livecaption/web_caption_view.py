"""Connect browser captions to EchoPane's existing translation and overlay."""

import os
import sys
import tkinter as tk
from pathlib import Path
from queue import Empty, SimpleQueue
from threading import Thread
from tkinter import ttk

from text_translation import TranslationError, translate
from views import PAGE_PADDING, page_title, wrap_label
from web_caption import BrowserCaptionConnection


PLAYER_HINTS = {
    "no_video": "这个标签页没有可读取的视频。",
    "no_track": "这个播放器没有提供可读取的字幕轨。可以切换到播放声音转字幕。",
    "off": "请在视频播放器中开启字幕。",
    "loading": "正在等待播放器载入字幕轨…",
    "track_error": "字幕轨加载失败。可以切换字幕轨或使用播放声音转字幕。",
    "seeking": "正在同步到新的播放位置…",
    "ended": "播放已结束。再次播放时会继续同步。",
}


class WebCaptionPage(ttk.Frame):
    def __init__(self, parent, *, configuration, can_start, caption_mode, set_active, show_caption, open_audio, glossary):
        super().__init__(parent, padding=PAGE_PADDING)
        self.configuration = configuration
        self.can_start = can_start
        self.caption_mode = caption_mode
        self.set_active = set_active
        self.show_caption = show_caption
        self.glossary = glossary
        self.bridge = None
        self.poll_job = None

        self.columnconfigure(0, weight=1)
        page_title(self, "网页字幕")
        ttk.Button(self, text="打开扩展目录", style="Outline.TButton", command=self.open_extension).grid(
            row=0, column=1, sticky="e",
        )
        intro = ttk.Label(self, style="Hint.TLabel", text="首次使用请在 Chrome 或 Edge 的扩展管理页开启开发者模式，"
                          "选择「加载已解压的扩展」并打开上述目录。"
                          "开启连接后，在视频标签页打开扩展并粘贴连接码。")
        intro.grid(row=1, columnspan=2, sticky="ew", pady=(6, 14))
        wrap_label(intro)

        panel = ttk.Frame(self, style="Panel.TFrame", padding=(14, 12))
        panel.grid(row=2, columnspan=2, sticky="ew", pady=(0, 10))
        panel.columnconfigure(0, weight=1)
        self.status = tk.StringVar(self, value="等待连接浏览器")
        state = ttk.Label(panel, style="Panel.TLabel", textvariable=self.status)
        state.grid(row=0, sticky="ew", pady=(0, 9))
        wrap_label(state)
        buttons = ttk.Frame(panel, style="Panel.TFrame")
        buttons.grid(row=1, sticky="w")
        self.connection_button = ttk.Button(buttons, text="开启连接", style="Primary.TButton", command=self.toggle)
        self.connection_button.pack(side="left")
        self.copy_button = ttk.Button(buttons, text="复制连接码", style="Outline.TButton", command=self.copy_code)
        self.copy_button.pack(side="left", padx=(6, 0))
        self.copy_button.state(["disabled"])
        self.retry_button = ttk.Button(panel, text="重试翻译", style="Quiet.TButton", command=self.retry)
        self.retry_button.grid(row=2, sticky="w", pady=(5, 0))
        self.retry_button.grid_remove()
        note = ttk.Label(self, style="Hint.TLabel", text="扩展读取当前标签页已开启的 HTML5 字幕轨。"
                         "翻译时，字幕正文会发送给百炼。")
        note.grid(row=3, columnspan=2, sticky="ew")
        wrap_label(note)
        self.audio_button = ttk.Button(self, text="使用播放声音转字幕", style="Quiet.TButton", command=open_audio)
        self.audio_button.grid(row=4, columnspan=2, sticky="w", pady=(8, 0))

    @property
    def active(self):
        return self.bridge is not None

    def open_extension(self):
        folder = Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent
        try:
            os.startfile(folder / "browser_extension")
        except OSError:
            self.status.set("找不到扩展目录，请检查 EchoPane 安装。")

    def toggle(self):
        if self.active:
            self.stop()
            return
        if not self.can_start():
            self.status.set("请先结束播放声音的字幕会话。")
            return
        mode = self.caption_mode()
        configuration = () if mode == "original" else self.configuration()
        if configuration is None:
            self.status.set("请先配置百炼翻译服务。")
            return
        try:
            self.bridge = BrowserCaptionConnection()
        except OSError:
            self.status.set("无法开启本机连接。请重试。")
            return
        self.mode = mode
        self.profile = configuration
        self.connection_terms = self.glossary()
        self.results = SimpleQueue()
        self.cache = {}
        self.pending = False
        self.issue = ""
        self.set_active(True)
        self.connection_button.configure(text="断开连接")
        self.copy_button.state(["!disabled"])
        self.status.set("连接已开启。复制连接码，在视频标签页的扩展中粘贴。")
        self.poll_job = self.after(60, self.poll)

    def copy_code(self):
        if self.active:
            self.clipboard_clear()
            self.clipboard_append(self.bridge.code)
            self.status.set("已复制连接码。请在视频标签页打开扩展并粘贴。")

    def retry(self):
        self.issue = ""
        self.retry_button.grid_remove()

    def stop(self, message="等待连接浏览器"):
        if not self.active:
            return
        if self.poll_job is not None:
            self.after_cancel(self.poll_job)
            self.poll_job = None
        self.bridge.close()
        self.bridge = None
        self.profile = ()
        self.connection_terms = ()
        self.cache.clear()
        self.set_active(False)
        self.connection_button.configure(text="开启连接")
        self.copy_button.state(["disabled"])
        self.retry_button.grid_remove()
        self.status.set(message)

    @staticmethod
    def request_translation(text, profile, terms, results):
        try:
            translation, issue = translate(text, *profile, terms=terms), ""
        except TranslationError as exc:
            translation, issue = "", str(exc)
        except Exception:
            translation, issue = "", "无法翻译当前字幕，请重试。"
        results.put((text, translation, issue))

    def poll(self):
        self.poll_job = None
        snapshot, finished = self.bridge.snapshot()
        if finished:
            self.stop("浏览器连接已断开。再次使用时请开启新连接。")
            return
        try:
            text, translated, issue = self.results.get_nowait()
        except Empty:
            pass
        else:
            self.pending = False
            self.issue = issue
            if issue:
                self.retry_button.grid()
            else:
                self.cache[text] = translated
                if len(self.cache) > 256:
                    del self.cache[next(iter(self.cache))]

        if snapshot is not None:
            self.copy_button.state(["disabled"])
            self.render_caption(snapshot)
            if self.mode != "original" and not (self.pending or self.issue):
                text = next((text for text in (snapshot.text, snapshot.upcoming) if text and text not in self.cache), "")
                if text:
                    self.pending = True
                    Thread(target=self.request_translation,
                           args=(text, self.profile, self.connection_terms, self.results), daemon=True).start()
        self.poll_job = self.after(60, self.poll)

    def render_caption(self, snapshot):
        translated = self.cache.get(snapshot.text, "")
        text = snapshot.text if self.mode == "original" else translated
        self.show_caption(text, snapshot.text if text and self.mode == "bilingual" else None)
        status = PLAYER_HINTS.get(snapshot.state)
        if status is None:
            label = snapshot.track or "网页字幕"
            if self.issue:
                status = self.issue
            elif snapshot.text and not text:
                status = f"{label}　正在翻译…"
            else:
                status = f"{label}　{'已暂停' if snapshot.state == 'paused' else '已同步'}"
        if self.status.get() != status:
            self.status.set(status)
