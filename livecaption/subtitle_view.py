"""Translate an imported subtitle file without blocking the workspace."""

import tkinter as tk
from queue import Empty, SimpleQueue
from threading import Event, Thread
from tkinter import filedialog, ttk

from cloud import service_host
from subtitle_file import SubtitleFile, SubtitleFileError
from text_translation import TranslationError, translate
from views import KEY_HINT, PAGE_PADDING, page_title, wrap_label


FILE_TYPES = (("字幕文件", "*.srt *.vtt *.webvtt"), ("SRT", "*.srt"), ("WebVTT", "*.vtt *.webvtt"))


def preview(text):
    text = " ".join(text.split())
    return text if len(text) <= 140 else text[:140] + "…"


class SubtitlePage(ttk.Frame):
    def __init__(self, parent, *, configuration, configure_service, glossary):
        super().__init__(parent, padding=PAGE_PADDING)
        self.configuration = configuration
        self.glossary = glossary
        self.job_terms = None
        self.document = None
        self.translations = {}
        self.completed = 0
        self.busy = False
        self.cancelled = Event()
        self.events = SimpleQueue()
        self.first_text = ""

        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)
        page_title(self, "字幕文件")
        self.open_button = ttk.Button(self, text="导入字幕…", style="Outline.TButton", command=self.open_file)
        self.open_button.grid(row=0, column=1, sticky="e")

        self.filename = tk.StringVar(self, value="选择 SRT 或 WebVTT 文件")
        self.original = tk.StringVar(self, value="—")
        self.translated = tk.StringVar(self, value="—")
        self.status = tk.StringVar(self, value="开始翻译后，字幕正文会发送给百炼。")

        title = ttk.Label(self, textvariable=self.filename, style="Hint.TLabel")
        title.grid(row=1, columnspan=2, sticky="ew", pady=(6, 10))
        wrap_label(title)
        samples = ttk.Frame(self)
        samples.grid(row=2, columnspan=2, sticky="nsew", pady=(0, 10))
        samples.rowconfigure(0, weight=1)
        for col, label, value in ((0, "原文预览", self.original), (1, "译文预览", self.translated)):
            samples.columnconfigure(col, weight=1, uniform="sample")
            card = ttk.Frame(samples, style="Panel.TFrame", padding=(12, 10))
            card.grid(row=0, column=col, sticky="nsew", padx=(0, 4) if col == 0 else (4, 0))
            card.columnconfigure(0, weight=1)
            ttk.Label(card, text=label, style="PanelSection.TLabel").grid(row=0, column=0, sticky="w")
            content = ttk.Label(card, textvariable=value, style="Panel.TLabel", anchor="nw")
            content.grid(row=1, column=0, sticky="ew", pady=(8, 0))
            wrap_label(content)

        self.progress = ttk.Progressbar(self, style="Subtitle.Horizontal.TProgressbar", maximum=1)
        self.progress.grid(row=3, columnspan=2, sticky="ew")
        state = ttk.Label(self, textvariable=self.status, style="Hint.TLabel")
        state.grid(row=4, columnspan=2, sticky="ew", pady=(6, 9))
        wrap_label(state)

        actions = ttk.Frame(self)
        actions.grid(row=5, columnspan=2, sticky="ew")
        self.start_button = ttk.Button(actions, text="开始翻译", style="Primary.TButton", command=self.start)
        self.start_button.pack(side="left")
        self.cancel_button = ttk.Button(actions, text="取消", style="Quiet.TButton", command=self.cancel)
        self.cancel_button.pack(side="left", padx=(4, 0))
        self.bilingual_button = ttk.Button(actions, text="导出双语…", style="Outline.TButton",
                                           command=lambda: self.save_file(bilingual=True))
        self.bilingual_button.pack(side="right")
        self.translation_button = ttk.Button(actions, text="导出译文…", style="Outline.TButton",
                                             command=lambda: self.save_file(bilingual=False))
        self.translation_button.pack(side="right", padx=(0, 6))
        self.settings_button = ttk.Button(self, text="打开翻译服务设置", style="Quiet.TButton",
                                          command=configure_service)
        self.settings_button.grid(row=6, columnspan=2, sticky="w", pady=(4, 0))
        self.settings_button.grid_remove()
        self.sync_buttons()

    def sync_buttons(self):
        complete = self.document is not None and self.completed == self.document.total
        for button, enabled in (
            (self.open_button, not self.busy),
            (self.start_button, not self.busy and self.document is not None and not complete),
            (self.cancel_button, self.busy and not self.cancelled.is_set()),
            (self.translation_button, not self.busy and complete),
            (self.bilingual_button, not self.busy and complete),
        ):
            button.state(["!disabled" if enabled else "disabled"])

    def open_file(self):
        if self.busy:
            return
        path = filedialog.askopenfilename(parent=self.winfo_toplevel(), title="导入字幕", filetypes=FILE_TYPES)
        if not path or self.busy:
            return
        try:
            document = SubtitleFile(path)
        except SubtitleFileError as exc:
            self.status.set(str(exc))
            return
        except OSError:
            self.status.set("无法读取字幕文件，请检查文件是否可访问。")
            return
        self.document = document
        self.job_terms = None
        self.translations.clear()
        self.completed = 0
        self.first_text = next(iter(document.counts))
        self.filename.set(f"{document.path.name} · {document.total} 段")
        self.original.set(preview(self.first_text))
        self.translated.set("—")
        self.progress.configure(maximum=document.total, value=0)
        self.status.set("准备就绪。开始翻译后，字幕正文会发送给百炼。")
        self.start_button.configure(text="开始翻译")
        self.settings_button.grid_remove()
        self.sync_buttons()

    def start(self):
        if self.busy or self.document is None or self.completed == self.document.total:
            return
        key, workspace = self.configuration()
        if not key:
            self.status.set(KEY_HINT)
            self.settings_button.grid()
            return
        try:
            service_host(workspace)
        except ValueError as exc:
            self.status.set(str(exc))
            self.settings_button.grid()
            return

        pending = [text for text in self.document.counts if text not in self.translations]
        if self.job_terms is None:
            self.job_terms = self.glossary()
        terms = self.job_terms
        self.cancelled.clear()
        self.busy = True
        self.settings_button.grid_remove()
        self.status.set(f"正在翻译 · {self.completed} / {self.document.total} 段")
        self.sync_buttons()

        def worker():
            error = ""
            try:
                for text in pending:
                    if self.cancelled.is_set():
                        break
                    self.events.put((text, translate(text, key, workspace, terms=terms)))
            except TranslationError as exc:
                error = str(exc)
            except Exception:
                error = "无法完成翻译，请检查翻译服务或重试。"
            self.events.put((None, error))

        Thread(target=worker, daemon=True).start()
        self.after(40, self.receive)

    def cancel(self):
        if self.busy and not self.cancelled.is_set():
            self.cancelled.set()
            self.status.set("正在取消，等待当前请求结束…")
            self.sync_buttons()

    def receive(self):
        while True:
            try:
                text, result = self.events.get_nowait()
            except Empty:
                self.after(40, self.receive)
                return
            if text is None:
                break
            self.translations[text] = result
            self.completed += self.document.counts[text]
            self.progress.configure(value=self.completed)
            if text == self.first_text:
                self.translated.set(preview(result))
            if not self.cancelled.is_set():
                self.status.set(f"正在翻译 · {self.completed} / {self.document.total} 段")

        self.busy = False
        count = f"{self.completed} / {self.document.total} 段"
        if self.completed == self.document.total:
            self.status.set(f"翻译完成 · {count}")
        elif self.cancelled.is_set():
            self.status.set(f"已取消 · 保留 {count} 的译文，可以继续翻译。")
            self.start_button.configure(text="继续翻译")
        else:
            self.status.set(f"已完成 {count}。{result}")
            self.start_button.configure(text="重试翻译")
        self.sync_buttons()

    def save_file(self, *, bilingual):
        if self.busy or self.document is None or self.completed != self.document.total:
            return
        source = self.document.path
        suffix = source.suffix.lower()
        designation = "bilingual" if bilingual else "zh"
        path = filedialog.asksaveasfilename(parent=self.winfo_toplevel(), title="导出字幕", defaultextension=suffix,
                                            initialdir=source.parent, initialfile=f"{source.stem}.{designation}{suffix}",
                                            filetypes=((self.document.format.upper(), f"*{suffix}"),))
        if not path:
            return
        try:
            self.document.export(path, self.translations, bilingual=bilingual)
        except SubtitleFileError as exc:
            self.status.set(str(exc))
        except (OSError, ValueError):
            self.status.set("无法导出字幕，请检查保存位置后重试。")
        else:
            self.status.set("已导出双语字幕。" if bilingual else "已导出中文字幕。")
