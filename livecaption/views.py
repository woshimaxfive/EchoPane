"""Workspace pages and the shared live session bar."""

import os
import tkinter as tk
import webbrowser
from functools import partial
from tkinter import font, ttk

import theme
from capture import AudioSource, window_sources
from cloud import service_url
from credentials import clear_credentials, load_credentials, save_credentials
from preferences import BACKGROUNDS, CAPTION_SIZES
from session import Phase


LIVE_TITLE = "实时字幕"
APPEARANCE_TITLE = "字幕外观"
SOURCE_HINT = "选择要加字幕的窗口"
KEY_HINT = "请先填写百炼北京地域的 API Key。"
CAPTION_SAMPLE = "沿着海岸，前面就是那片沙滩。"
CAPTION_SAMPLE_ORIGINAL = "The beach is up the coast."
PAGE_PADDING = (theme.GUTTER, 15, theme.GUTTER, 16)
SECTION_GAP = (12, 0)
SECTION_PADDING = (16, 13)


def page_title(page, title):
    scale = max(1.0, float(page.tk.call("tk", "scaling")) * 0.75)
    page.rowconfigure(0, minsize=round(41 * scale))
    ttk.Label(page, text=title, style="PageTitle.TLabel").grid(row=0, column=0, sticky="w")


def wrap_label(label):
    label.bind("<Configure>", lambda event: label.configure(wraplength=max(1, event.width - 2)))


def segmented_choices(parent, variable, choices, on_change):
    track = ttk.Frame(parent, style="SegmentTrack.TFrame", padding=3)
    for column, (value, title) in enumerate(choices):
        track.columnconfigure(column, weight=1, uniform="choice")
        ttk.Radiobutton(track, text=title, value=value, variable=variable, style="Segment.TRadiobutton",
                        command=lambda: on_change(variable.get())).grid(row=0, column=column, sticky="ew")
    return track


class SessionBar(ttk.Frame):
    def __init__(self, parent, start, stop):
        super().__init__(parent, style="Status.TFrame", padding=(theme.GUTTER, 9))
        self.columnconfigure(1, weight=1)
        self.signal = tk.Canvas(self, width=10, height=12, highlightthickness=0, bg=theme.STATUS_BACKGROUND)
        self.dot = self.signal.create_oval(1, 3, 8, 10, width=0, fill=theme.MUTED)
        self.signal.grid(row=0, column=0, sticky="w", padx=(0, 7))
        self.phase = ttk.Label(self, style="Phase.TLabel")
        self.phase.grid(row=0, column=1, sticky="w")
        self.detail = ttk.Label(self, style="Detail.TLabel", wraplength=380)
        self.detail.grid(row=1, column=1, sticky="ew", pady=(2, 0))
        wrap_label(self.detail)
        self.play_icon = theme.glyph(self, "play", theme.BUTTON_TEXT)
        self.stop_icon = theme.glyph(self, "stop", theme.BUTTON_TEXT)
        self.pending_icon = theme.glyph(self, "stop", theme.MUTED)
        self.action = ttk.Button(self, style="Primary.TButton", compound="left", width=10)
        self.action.grid(row=0, column=2, rowspan=2, sticky="e", padx=(16, 0))
        self.start = start
        self.stop = stop
        self.presentation = None

    def show(self, state, idle_title, idle_detail, *, compact=False):
        phase = state.phase
        title = idle_title if phase is Phase.IDLE else phase.value
        detail = idle_detail if phase is Phase.IDLE else state.message
        if compact:
            detail = ""
        signal = theme.ACCENT if state.active else theme.MUTED
        if phase is Phase.IDLE and title == "可以开始":
            signal = theme.READY
        if phase is Phase.INTERRUPTED:
            signal = theme.WARNING
        presentation = phase, title, detail, compact
        if self.presentation == presentation:
            return
        if self.presentation is None or self.presentation[-1] != compact:
            self.configure(padding=(theme.GUTTER, 3 if compact else 9))
            self.action.configure(style="StatusQuiet.TButton" if compact else "Primary.TButton",
                                  width=0 if compact else 10)
            self.action.grid_configure(rowspan=1 if compact else 2)
            if compact:
                self.detail.grid_remove()
            else:
                self.detail.grid()
        self.presentation = presentation
        self.signal.itemconfigure(self.dot, fill=signal)
        self.phase.configure(text=title, foreground=theme.WARNING if phase is Phase.INTERRUPTED else theme.TEXT)
        self.detail.configure(text=detail)
        if compact:
            text = "正在停止…" if phase is Phase.STOPPING else "停止"
            command = self.stop
            icon = ""
        elif state.active:
            text = "正在停止…" if phase is Phase.STOPPING else "停止字幕"
            command = self.stop
            icon = self.pending_icon if phase is Phase.STOPPING else self.stop_icon
        else:
            text = "重新开始" if phase is Phase.INTERRUPTED else "开始字幕"
            command = self.start
            icon = self.play_icon
        self.action.configure(text=text, image=icon, command=command)
        self.action.state(["disabled"] if phase is Phase.STOPPING else ["!disabled"])


class LivePage(ttk.Frame):
    def __init__(self, parent, source_changed, open_history):
        super().__init__(parent, padding=PAGE_PADDING)
        self.columnconfigure(0, weight=1)
        self.rowconfigure(2, weight=1)
        self.sources = {}
        self.source_changed = source_changed
        page_title(self, LIVE_TITLE)
        self.history_button = ttk.Button(self, text="字幕回看", style="Outline.TButton", command=open_history)
        self.history_button.grid(row=0, column=1, sticky="e")

        audio = ttk.Frame(self, style="Panel.TFrame", padding=SECTION_PADDING)
        audio.grid(row=1, columnspan=2, sticky="ew", pady=SECTION_GAP)
        audio.columnconfigure(1, weight=1)
        ttk.Label(audio, text="播放窗口", style="PanelSection.TLabel").grid(row=0, column=0, sticky="w")
        self.refresh_button = ttk.Button(audio, text="↻ 刷新", style="PanelQuiet.TButton", command=self.refresh)
        self.refresh_button.grid(row=0, column=2, sticky="e")
        self.source = ttk.Combobox(audio, state="readonly", width=20, height=8)
        self.source.grid(row=1, columnspan=3, sticky="ew", pady=(7, 14))
        self.source.set(SOURCE_HINT)
        self.source.bind("<<ComboboxSelected>>", lambda _event: self.source_changed())

        ttk.Frame(audio, height=1, style="Divider.TFrame").grid(row=2, columnspan=3, sticky="ew")
        self.meter = theme.LevelMeter(audio)
        ttk.Label(audio, text="输入电平", style="Panel.TLabel").grid(row=3, column=0, sticky="w", pady=(11, 0))
        self.meter.grid(row=3, column=1, sticky="ew", padx=(14, 0), pady=(11, 0))
        ttk.Label(audio, textvariable=self.meter.reading, style="MeterValue.TLabel", width=5, anchor="e").grid(
            row=3, column=2, sticky="e", pady=(11, 0)
        )
        notice = ttk.Label(self, text="音频将发往阿里云。同一浏览器的其他发声标签页也可能被采集。",
                           style="Hint.TLabel", wraplength=400)
        notice.grid(row=2, columnspan=2, sticky="sew", pady=(10, 0))
        wrap_label(notice)

    def refresh(self):
        previous = self.selected_source()
        self.sources = window_sources()
        self.source.configure(values=tuple(self.sources))
        current = next((label for label, process in self.sources.items() if process == previous), SOURCE_HINT)
        self.source.set(current)
        self.source_changed()

    def selected_source(self):
        return self.sources.get(self.source.get())

    def input_ready(self):
        return self.selected_source() is not None

    def source_prompt(self):
        if not self.sources:
            return "请先打开要加字幕的窗口，再刷新列表。"
        return "请选择要加字幕的播放窗口。"

    def capture_factory(self):
        source = self.selected_source()
        if source is None:
            raise RuntimeError(self.source_prompt())
        if not source.is_running():
            raise RuntimeError("请刷新并选择正在播放的程序。")
        return partial(AudioSource, source)

    def set_active(self, active):
        self.source.configure(state="disabled" if active else "readonly")
        self.refresh_button.state(["disabled"] if active else ["!disabled"])


class CaptionPreview(tk.Canvas):
    def __init__(self, parent, appearance, scale):
        super().__init__(parent, background=theme.CAPTION_BG, width=1, height=round(126 * scale),
                         highlightthickness=0)
        self.photo = tk.PhotoImage(master=self, file=str(theme.asset_path("caption-preview.png")))
        self.scene = self.create_image(0, 0, image=self.photo)
        self.shade = self.create_rectangle(0, 0, 0, 0, fill=theme.CAPTION_BG, outline="")
        self.text_font = font.Font(root=self, family=theme.FONT, size=appearance.caption_size)
        self.original_font = font.Font(root=self, family=theme.FONT,
                                      size=theme.secondary_caption_size(appearance.caption_size))
        self.offsets = ((1, 2), (-1, 0), (1, 0), (0, -1), (0, 1), (0, 0))
        self.caption = self.make_text(CAPTION_SAMPLE, self.text_font, theme.CAPTION_TEXT, "caption")
        self.original = self.make_text(CAPTION_SAMPLE_ORIGINAL, self.original_font, theme.CAPTION_PREVIOUS, "original")
        self.background_mode = appearance.background
        self.bilingual = appearance.bilingual
        self.bind("<Configure>", self.redraw)

    def make_text(self, text, text_font, color, tag):
        return [
            self.create_text(0, 0, text=text, anchor="s", justify="center",
                             font=text_font, fill=theme.CAPTION_STROKE if offset != (0, 0) else color,
                             tags=(tag,))
            for offset in self.offsets
        ]

    def show_appearance(self, appearance):
        self.text_font.configure(size=appearance.caption_size)
        self.original_font.configure(size=theme.secondary_caption_size(appearance.caption_size))
        self.background_mode = appearance.background
        self.bilingual = appearance.bilingual
        self.redraw()

    def redraw(self, _event=None):
        width, height = self.winfo_width(), self.winfo_height()
        self.coords(self.scene, width / 2, height / 2)
        self.itemconfigure("caption", width=max(1, width - 34))
        for item, (dx, dy) in zip(self.caption, self.offsets):
            self.coords(item, width / 2 + dx, height - 15 + dy)
        left, top, right, bottom = self.bbox(self.caption[-1])
        self.itemconfigure("original", width=max(1, width - 34), state="normal" if self.bilingual else "hidden")
        if self.bilingual:
            for item, (dx, dy) in zip(self.original, self.offsets):
                self.coords(item, width / 2 + dx, top - 4 + dy)
            source_left, source_top, source_right, _ = self.bbox(self.original[-1])
            left, top, right = min(left, source_left), source_top, max(right, source_right)
        self.coords(self.shade, left - 10, top - 3, right + 10, bottom + 3)
        self.itemconfigure(self.shade, state="normal" if self.background_mode == "shade" else "hidden")


class CaptionPage(ttk.Frame):
    def __init__(self, parent, appearance, scale, *, change_size, change_background, change_lock,
                 change_bilingual, show_overlay):
        super().__init__(parent, padding=PAGE_PADDING)
        self.columnconfigure((0, 1), weight=1, uniform="appearance")
        self.rowconfigure(1, weight=1)
        page_title(self, APPEARANCE_TITLE)
        self.preview_button = ttk.Button(self, text="显示浮窗", style="Outline.TButton", command=show_overlay)
        self.preview_button.grid(row=0, column=1, sticky="e")
        screen = ttk.Frame(self, style="Preview.TFrame", padding=4)
        screen.grid(row=1, columnspan=2, sticky="nsew", pady=(13, 11))
        self.preview = CaptionPreview(screen, appearance, scale)
        self.preview.pack(fill="both", expand=True)

        ttk.Label(self, text="字号（磅）").grid(row=2, column=0, sticky="w")
        ttk.Label(self, text="背景").grid(row=2, column=1, sticky="w", padx=(12, 0))
        self.size = tk.IntVar(master=self)
        self.background = tk.StringVar(master=self)
        self.size_choice = segmented_choices(self, self.size, [(size, str(size)) for size in CAPTION_SIZES], change_size)
        self.size_choice.grid(row=3, column=0, sticky="ew", pady=(5, 0))
        self.background_choice = segmented_choices(self, self.background, BACKGROUNDS.items(), change_background)
        self.background_choice.grid(row=3, column=1, sticky="ew", padx=(12, 0), pady=(5, 0))
        ttk.Label(self, text="字幕内容").grid(row=4, column=0, sticky="w", pady=(12, 0))
        self.bilingual = tk.BooleanVar(master=self)
        self.language_choice = segmented_choices(self, self.bilingual, ((False, "仅译文"), (True, "双语")),
                                                 change_bilingual)
        self.language_choice.grid(row=5, column=0, sticky="ew", pady=(5, 0))
        self.locked = tk.BooleanVar(master=self)
        ttk.Checkbutton(self, text="锁定浮窗位置", variable=self.locked,
                        command=lambda: change_lock(self.locked.get())).grid(
            row=4, column=1, sticky="w", padx=(12, 0), pady=(12, 0))
        self.notice = ttk.Label(self, style="Hint.TLabel")
        self.notice.grid(row=5, column=1, sticky="ew", padx=(12, 0), pady=(5, 0))
        wrap_label(self.notice)
        self.show_appearance(appearance)

    def show_appearance(self, appearance):
        self.size.set(appearance.caption_size)
        self.background.set(appearance.background)
        self.locked.set(appearance.locked)
        self.bilingual.set(appearance.bilingual)
        self.preview.show_appearance(appearance)

    def set_active(self, active):
        for button in self.language_choice.winfo_children():
            button.state(["disabled"] if active else ["!disabled"])


class SettingsPage(ttk.Frame):
    def __init__(self, parent, key_changed):
        super().__init__(parent, padding=PAGE_PADDING)
        self.columnconfigure(0, weight=1)
        self.notice = tk.StringVar(master=self, value="保存后由 Windows 凭据管理器保管。")
        key = os.getenv("DASHSCOPE_API_KEY", "")
        workspace = os.getenv("DASHSCOPE_WORKSPACE", "")
        if not key:
            try:
                saved_key, saved_workspace = load_credentials()
                if saved_key:
                    key, workspace = saved_key, saved_workspace
            except (OSError, ValueError):
                self.notice.set("无法读取先前保存的配置，请手动填写 Key。")
        self.key = tk.StringVar(master=self, value=key)
        self.workspace = tk.StringVar(master=self, value=workspace)
        self.key.trace_add("write", key_changed)
        self.workspace.trace_add("write", key_changed)

        page_title(self, "翻译服务")
        provider = ttk.Frame(self, style="Panel.TFrame", padding=SECTION_PADDING)
        provider.grid(row=1, sticky="ew", pady=SECTION_GAP)
        provider.columnconfigure(0, weight=1)
        ttk.Label(provider, text="阿里云百炼", style="PanelSection.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(provider, text="北京地域", style="PanelHint.TLabel").grid(row=0, column=1, sticky="e")
        field = ttk.Frame(provider, style="PanelInner.TFrame")
        field.grid(row=1, columnspan=2, sticky="ew", pady=(10, 0))
        field.columnconfigure(1, weight=1)
        ttk.Label(field, text="API Key", width=12, style="Panel.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Button(field, text="获取 Key ↗", style="PanelQuiet.TButton", command=lambda: webbrowser.open(
            "https://help.aliyun.com/zh/model-studio/get-api-key"
        )).grid(row=0, column=2, sticky="e", padx=(8, 0))
        self.key_entry = ttk.Entry(field, textvariable=self.key, show="●")
        self.key_entry.grid(row=0, column=1, sticky="ew")

        ttk.Frame(provider, height=1, style="Divider.TFrame").grid(row=2, columnspan=2, sticky="ew", pady=(10, 0))

        self.advanced_button = ttk.Button(provider, style="PanelQuiet.TButton", command=self.toggle_advanced)
        self.advanced_button.grid(row=3, sticky="w", pady=(5, 0))
        self.advanced = ttk.Frame(provider, style="PanelInner.TFrame")
        self.advanced.grid(row=4, columnspan=2, sticky="ew", pady=(4, 0))
        self.advanced.columnconfigure(1, weight=1)
        ttk.Label(self.advanced, text="业务空间 ID", width=12, style="Panel.TLabel").grid(row=0, column=0, sticky="w")
        self.workspace_entry = ttk.Entry(self.advanced, textvariable=self.workspace)
        self.workspace_entry.grid(row=0, column=1, sticky="ew")
        self.show_advanced(bool(workspace))

        controls = ttk.Frame(self)
        controls.grid(row=2, sticky="ew", pady=(12, 0))
        self.save_button = ttk.Button(controls, text="保存配置", style="Outline.TButton", command=self.save)
        self.save_button.pack(side="left")
        self.clear_button = ttk.Button(controls, text="清除配置", style="Quiet.TButton", command=self.clear)
        self.clear_button.pack(side="left", padx=theme.SPACE)
        note = ttk.Label(self, textvariable=self.notice, style="Hint.TLabel", wraplength=410)
        note.grid(row=3, sticky="ew", pady=(8, 0))
        wrap_label(note)

    def show_advanced(self, opened):
        self.advanced_open = opened
        self.advanced_button.configure(text="▾  高级设置" if opened else "▸  高级设置")
        if opened:
            self.advanced.grid()
        else:
            self.advanced.grid_remove()

    def toggle_advanced(self):
        self.show_advanced(not self.advanced_open)

    def configuration(self):
        return self.key.get().strip(), self.workspace.get().strip()

    def set_active(self, active):
        for control in (self.key_entry, self.workspace_entry, self.save_button, self.clear_button):
            control.state(["disabled"] if active else ["!disabled"])

    def save(self):
        key, workspace = self.configuration()
        if not key:
            self.notice.set(KEY_HINT)
            self.key_entry.focus_set()
            return
        try:
            service_url(workspace)
            save_credentials(key, workspace)
        except ValueError as exc:
            self.notice.set(str(exc))
        except OSError:
            self.notice.set("无法保存到 Windows 凭据管理器。当前填写的 Key 仍可用于本次会话。")
        else:
            self.notice.set("配置已保存到 Windows 凭据管理器。")

    def clear(self):
        try:
            clear_credentials()
        except OSError:
            self.notice.set("无法从 Windows 凭据管理器清除配置，请重试。")
        else:
            self.key.set("")
            self.workspace.set("")
            self.notice.set("已清除本机保存的配置。")
