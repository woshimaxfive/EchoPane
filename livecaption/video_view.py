"""Generate and export subtitles for a local media file without using the playback device."""

import tkinter as tk
from pathlib import Path
from queue import Empty, SimpleQueue
from threading import Event, Thread
from tkinter import filedialog, ttk

from cloud import service_host
from subtitle_file import SubtitleFileError
from subtitle_view import preview
from text_translation import TranslationError, translate
from video_asr import RecognitionError, recognize
from video_audio import MEDIA_EXTENSIONS, MediaError, audio_blocks, audio_duration
from video_captions import export_captions, make_captions
from views import KEY_HINT, PAGE_PADDING, page_title, wrap_label


def clock(milliseconds):
    hours, remainder = divmod(milliseconds // 1000, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}" if hours else f"{minutes:02}:{seconds:02}"


def fingerprint(path):
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


class VideoPage(ttk.Frame):
    def __init__(self, parent, *, configuration, configure_service, glossary):
        super().__init__(parent, padding=PAGE_PADDING)
        self.configuration = configuration
        self.glossary = glossary
        self.source = self.identity = None
        self.duration = self.covered = 0
        self.captions = []
        self.translations = {}
        self.translation_terms = None
        self.generated = False
        self.busy = None
        self.cancelled = Event()
        self.events = SimpleQueue()

        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)
        page_title(self, "视频字幕")
        self.open_button = ttk.Button(self, text="导入视频…", style="Outline.TButton", command=self.choose_file)
        self.open_button.grid(row=0, column=1, sticky="e")

        self.filename = tk.StringVar(self, value="从本机选择有声音的视频或音频")
        file_label = ttk.Label(self, textvariable=self.filename, style="Hint.TLabel")
        file_label.grid(row=1, columnspan=2, sticky="ew", pady=(6, 10))
        wrap_label(file_label)

        samples = ttk.Frame(self)
        samples.grid(row=2, columnspan=2, sticky="nsew", pady=(0, 10))
        samples.rowconfigure(0, weight=1)
        self.original = tk.StringVar(self, value="—")
        self.translation = tk.StringVar(self, value="—")
        for column, (title, variable) in enumerate((("原文预览", self.original), ("中文预览", self.translation))):
            samples.columnconfigure(column, weight=1, uniform="preview")
            panel = ttk.Frame(samples, style="Panel.TFrame", padding=(12, 10))
            panel.grid(row=0, column=column, sticky="nsew", padx=(0, 4) if column == 0 else (4, 0))
            panel.columnconfigure(0, weight=1)
            ttk.Label(panel, text=title, style="PanelSection.TLabel").grid(row=0, sticky="w")
            label = ttk.Label(panel, textvariable=variable, style="Panel.TLabel")
            label.grid(row=1, sticky="ew", pady=(8, 0))
            wrap_label(label)

        self.progress = ttk.Progressbar(self, style="Subtitle.Horizontal.TProgressbar", maximum=1)
        self.progress.grid(row=3, columnspan=2, sticky="ew")
        self.status = tk.StringVar(self, value="在本机提取第一条音轨，将音频分段发送给百炼转写。")
        notice = ttk.Label(self, textvariable=self.status, style="Hint.TLabel")
        notice.grid(row=4, columnspan=2, sticky="ew", pady=(6, 8))
        wrap_label(notice)

        actions = ttk.Frame(self)
        actions.grid(row=5, columnspan=2, sticky="ew")
        self.generate_button = ttk.Button(actions, text="生成原文", style="Primary.TButton", command=self.start_generation)
        self.generate_button.pack(side="left")
        self.translate_button = ttk.Button(actions, text="翻译为双语", style="Outline.TButton", command=self.start_translation)
        self.translate_button.pack(side="left", padx=(6, 0))
        self.cancel_button = ttk.Button(actions, text="取消", style="Quiet.TButton", command=self.cancel)
        self.cancel_button.pack(side="left", padx=(2, 0))

        exports = ttk.Frame(self)
        exports.grid(row=6, columnspan=2, sticky="ew", pady=(6, 0))
        self.settings_button = ttk.Button(exports, text="服务设置…", style="Quiet.TButton", command=configure_service)
        self.settings_button.pack(side="left")
        self.bilingual_button = ttk.Button(exports, text="导出双语…", style="Outline.TButton",
                                           command=lambda: self.save_file(bilingual=True))
        self.bilingual_button.pack(side="right")
        self.original_button = ttk.Button(exports, text="导出原文…", style="Outline.TButton",
                                          command=lambda: self.save_file(bilingual=False))
        self.original_button.pack(side="right", padx=(0, 6))
        self.sync_buttons()

    def sync_buttons(self):
        idle = self.busy is None
        has_captions = self.generated and bool(self.captions)
        for button, enabled in (
            (self.open_button, idle),
            (self.generate_button, idle and self.source is not None and not self.generated),
            (self.translate_button, idle and has_captions and len(self.translations) < len(self.unique_texts())),
            (self.cancel_button, not idle and not self.cancelled.is_set()),
            (self.original_button, idle and has_captions),
            (self.bilingual_button, idle and has_captions and len(self.translations) == len(self.unique_texts())),
        ):
            button.state(["!disabled" if enabled else "disabled"])
        self.generate_button.configure(text="继续生成" if self.covered and not self.generated else "生成原文")
        self.translate_button.configure(text="继续翻译" if self.translations and self.translate_button.instate(["!disabled"])
                                        else "翻译为双语")

    def unique_texts(self):
        return dict.fromkeys(cue.text for cue in self.captions)

    def choose_file(self):
        if self.busy:
            return
        formats = " ".join("*" + ext for ext in sorted(MEDIA_EXTENSIONS))
        selected = filedialog.askopenfilename(parent=self.winfo_toplevel(), title="导入本地视频",
                                              filetypes=(("媒体文件", formats),))
        if not selected:
            return
        try:
            source = Path(selected).resolve(strict=True)
            if source.suffix.casefold() not in MEDIA_EXTENSIONS or not source.is_file():
                raise ValueError
            identity = fingerprint(source)
        except (OSError, ValueError):
            self.status.set("无法打开媒体文件，请检查文件的位置和格式。")
            return
        self.source, self.identity = source, identity
        self.duration = self.covered = 0
        self.captions.clear()
        self.translations.clear()
        self.translation_terms = None
        self.generated = False
        self.original.set("—")
        self.translation.set("—")
        self.filename.set(source.name)
        self.progress.configure(mode="determinate", maximum=1, value=0)
        self.status.set("点击「生成原文」开始。音频发送给百炼并计入当前账户用量。")
        self.sync_buttons()

    def profile(self):
        key, workspace = self.configuration()
        if not key:
            self.status.set(KEY_HINT)
            return None
        try:
            service_host(workspace)
        except ValueError as error:
            self.status.set(str(error))
            return None
        return key, workspace

    def start_generation(self):
        if self.busy or self.source is None or self.generated:
            return
        if not (profile := self.profile()):
            return
        source, identity, start = self.source, self.identity, self.covered

        def generate():
            verify_source(source, identity)
            self.events.put(("duration", audio_duration(source)))
            for block in audio_blocks(source, self.cancelled, start_ms=start):
                verify_source(source, identity)
                if self.cancelled.is_set():
                    break
                words = recognize(block.pcm, *profile)
                verify_source(source, identity)
                self.events.put(("captions", (block.end, make_captions(block, words))))

        self.run("asr", generate, "正在读取第一条音轨…")

    def start_translation(self):
        if self.busy or not self.generated:
            return
        pending = [text for text in self.unique_texts() if text not in self.translations]
        if not pending or not (profile := self.profile()):
            return
        if self.translation_terms is None:
            self.translation_terms = self.glossary()
        terms = self.translation_terms

        def translate_pending():
            for text in pending:
                if self.cancelled.is_set():
                    break
                translated = translate(text, *profile, terms=terms)
                self.events.put(("translation", (text, translated)))

        self.progress.configure(mode="determinate", maximum=len(self.unique_texts()), value=len(self.translations))
        self.run("translation", translate_pending, "正在翻译字幕…")

    def run(self, operation, work, notice):
        self.busy = operation
        self.cancelled.clear()
        self.status.set(notice)
        self.sync_buttons()

        def worker():
            error = ""
            try:
                work()
            except (MediaError, RecognitionError, TranslationError) as exc:
                error = str(exc)
            except OSError:
                error = "读取媒体时失败，请确认源文件仍然可访问。"
            except Exception:
                error = "无法处理此媒体文件，请检查音轨或转为 MP4 后重试。"
            finally:
                self.events.put(("done", error))

        Thread(target=worker, name="EchoPane video captions", daemon=True).start()
        self.after(40, self.receive)

    def cancel(self):
        if self.busy and not self.cancelled.is_set():
            self.cancelled.set()
            self.status.set("正在取消，等待当前请求结束…")
            self.sync_buttons()

    def receive(self):
        while True:
            try:
                kind, data = self.events.get_nowait()
            except Empty:
                self.after(40, self.receive)
                return
            if kind == "duration":
                self.duration = data
                self.progress.configure(mode="determinate" if data else "indeterminate", maximum=data or 1, value=self.covered)
                if not data:
                    self.progress.start()
                self.set_running_status(f"正在转写 · {clock(self.covered)}{f' / {clock(data)}' if data else ''}")
            elif kind == "captions":
                self.covered, captions = data
                self.captions.extend(captions)
                if self.captions:
                    self.original.set(preview(self.captions[0].text))
                if self.duration:
                    self.progress.configure(value=min(self.covered, self.duration))
                total = f" / {clock(self.duration)}" if self.duration else ""
                self.set_running_status(f"正在转写 · {clock(self.covered)}{total} · {len(self.captions)} 段")
            elif kind == "translation":
                original, translated = data
                self.translations[original] = translated
                if original == self.captions[0].text:
                    self.translation.set(preview(translated))
                self.progress.configure(value=len(self.translations))
                total = int(float(self.progress["maximum"]))
                self.set_running_status(f"正在翻译 · {len(self.translations)} / {total} 条")
            elif kind == "done":
                self.finish(data)
                return

    def set_running_status(self, message):
        if not self.cancelled.is_set():
            self.status.set(message)

    def finish(self, error):
        self.progress.stop()
        operation, self.busy = self.busy, None
        if self.cancelled.is_set():
            count = len(self.captions) if operation == "asr" else len(self.translations)
            self.status.set(f"已取消 · 已保留 {count} 段结果，可继续处理。")
        elif error:
            self.status.set(error)
        elif operation == "asr":
            self.generated = True
            total = self.duration or self.covered or 1
            self.progress.configure(mode="determinate", maximum=total, value=total)
            self.status.set(f"已生成 {len(self.captions)} 段原文字幕。" if self.captions else "音轨中没有识别到语音。")
        else:
            self.status.set(f"已生成 {len(self.captions)} 段双语字幕。")
        self.sync_buttons()

    def save_file(self, *, bilingual):
        if self.busy or not self.generated or not self.captions:
            return
        name = "bilingual" if bilingual else "original"
        destination = filedialog.asksaveasfilename(
            parent=self.winfo_toplevel(), title="导出视频字幕", defaultextension=".srt",
            initialdir=self.source.parent, initialfile=f"{self.source.stem}.{name}.srt",
            filetypes=(("SRT 字幕", "*.srt"), ("WebVTT 字幕", "*.vtt")),
        )
        if not destination:
            return
        try:
            export_captions(destination, self.captions, self.translations if bilingual else None)
        except SubtitleFileError as error:
            self.status.set(str(error))
        except (OSError, ValueError):
            self.status.set("无法写入字幕文件，请换一个位置后重试。")
        else:
            self.status.set("已导出双语字幕。" if bilingual else "已导出原文字幕。")


def verify_source(path, identity):
    if fingerprint(path) != identity:
        raise MediaError("源文件已变化，请重新导入后生成字幕。")
