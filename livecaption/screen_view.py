"""One-shot capture, OCR review and text translation in the workspace."""

import tkinter as tk
from queue import Empty, SimpleQueue
from threading import Thread
from tkinter import ttk

import theme
from cloud import service_host
from screen_capture import RegionSelector
from screen_ocr import recognize
from text_translation import MAX_TEXT_LENGTH, TranslationError, translate
from views import KEY_HINT, PAGE_PADDING, page_title, wrap_label


READY_TO_CAPTURE = "选取屏幕上的文字区域。识别在本机完成，点击翻译后才发送原文。"


class ScreenPage(ttk.Frame):
    def __init__(self, parent, *, hide_windows, configuration, configure_service):
        super().__init__(parent, padding=PAGE_PADDING)
        self.hide_windows = hide_windows
        self.configuration = configuration
        self.configure_service = configure_service
        self.results = SimpleQueue()
        self.busy = False
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        page_title(self, "屏幕翻译")
        self.select_button = ttk.Button(self, text="框选屏幕", style="Outline.TButton", command=self.select_region)
        self.select_button.grid(row=0, column=1, sticky="e")

        editors = ttk.Frame(self)
        editors.grid(row=1, columnspan=2, sticky="nsew", pady=(12, 9))
        editors.rowconfigure(0, weight=1)
        for column in (0, 1):
            editors.columnconfigure(column, weight=1, uniform="editor")
        self.original, _ = self.add_editor(editors, 0, "原文")
        self.translation, translation_panel = self.add_editor(editors, 1, "中文译文")
        self.original.configure(undo=True, insertbackground=theme.TEXT)
        self.original.bind("<<Modified>>", self.original_changed)
        self.translation.configure(state="disabled")
        self.copy_button = ttk.Button(translation_panel, text="复制", style="PanelQuiet.TButton", command=self.copy)
        self.copy_button.grid(row=0, column=1, sticky="e")

        self.status = tk.StringVar(self, value=READY_TO_CAPTURE)
        note = ttk.Label(self, textvariable=self.status, style="Hint.TLabel")
        note.grid(row=2, column=0, sticky="ew", padx=(0, 12), pady=(4, 0))
        wrap_label(note)
        self.translate_button = ttk.Button(self, text="翻译", style="Primary.TButton", command=self.translate_original)
        self.translate_button.grid(row=2, column=1, sticky="e", pady=(4, 0))
        self.settings_button = ttk.Button(self, text="打开翻译服务设置", style="Quiet.TButton",
                                          command=self.configure_service)
        self.settings_button.grid(row=3, columnspan=2, sticky="w", pady=(4, 0))
        self.settings_button.grid_remove()
        self.sync_buttons()

    def add_editor(self, parent, column, title):
        panel = ttk.Frame(parent, style="Panel.TFrame", padding=(12, 8, 8, 9))
        panel.grid(row=0, column=column, sticky="nsew", padx=(0, 5) if column == 0 else (5, 0))
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(1, weight=1)
        ttk.Label(panel, text=title, style="PanelSection.TLabel").grid(row=0, column=0, sticky="w", pady=(4, 5))
        box = tk.Text(panel, width=1, height=1, wrap="word", bg=theme.FIELD, fg=theme.TEXT, bd=0,
                      highlightthickness=1, highlightbackground=theme.BORDER, highlightcolor=theme.ACCENT,
                      selectbackground=theme.ACCENT, selectforeground=theme.BUTTON_TEXT,
                      font=(theme.FONT, 11), padx=8, pady=7, spacing2=3, exportselection=False)
        scrollbar = ttk.Scrollbar(panel, command=box.yview, style="History.Vertical.TScrollbar")
        box.configure(yscrollcommand=scrollbar.set)
        box.grid(row=1, column=0, sticky="nsew")
        scrollbar.grid(row=1, column=1, sticky="ns", padx=(2, 0))
        return box, panel

    def original_changed(self, _event):
        if self.original.edit_modified():
            self.original.edit_modified(False)
            self.show_translation("")
            self.settings_button.grid_remove()
            self.status.set("确认原文后点击翻译。")
            self.sync_buttons()

    def sync_buttons(self):
        has_source = bool(self.original.get("1.0", "end-1c").strip())
        self.select_button.state(["disabled"] if self.busy else ["!disabled"])
        self.translate_button.state(["!disabled"] if not self.busy and has_source else ["disabled"])
        self.copy_button.state(["!disabled"] if self.translation.get("1.0", "end-1c") else ["disabled"])
        self.original.configure(state="disabled" if self.busy else "normal")

    def show_translation(self, value):
        self.translation.configure(state="normal")
        self.translation.replace("1.0", "end", value)
        self.translation.configure(state="disabled")

    def copy(self):
        result = self.translation.get("1.0", "end-1c")
        if result:
            self.clipboard_clear()
            self.clipboard_append(result)
            self.status.set("已复制译文。")

    def select_region(self):
        if self.busy:
            return
        self.busy = True
        self.sync_buttons()
        self.settings_button.grid_remove()
        root = self.winfo_toplevel()
        restore = self.hide_windows()
        selector = None
        try:
            selector = RegionSelector(root, lambda pixels, status: self.region_ready(restore, pixels, status))
            selector.show()
        except (OSError, tk.TclError):
            if selector is not None:
                selector.destroy()
            self.region_ready(restore, None, "无法打开框选窗口，请重试。")

    def region_ready(self, restore, pixels, status):
        restore()
        if pixels is None:
            self.busy = False
            self.status.set(status)
            self.sync_buttons()
            self.select_button.focus_set()
            return
        self.original.configure(state="normal")
        self.original.delete("1.0", "end")
        self.original.edit_reset()
        self.original.edit_modified(False)
        self.show_translation("")
        self.run("ocr", "正在识别选区中的文字…", recognize, pixels)

    def translate_original(self):
        if self.busy:
            return
        text = self.original.get("1.0", "end-1c").strip()
        if not text:
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
        if len(text) > MAX_TEXT_LENGTH:
            self.status.set(f"本次最多翻译 {MAX_TEXT_LENGTH} 个字符，请缩短原文。")
            return
        self.settings_button.grid_remove()
        self.run("translation", "正在翻译原文…", translate, text, key, workspace)

    def run(self, operation, status, work, *args):
        self.busy = True
        self.status.set(status)
        self.sync_buttons()

        def worker():
            try:
                result = work(*args)
            except TranslationError as exc:
                self.results.put(("", str(exc)))
            except Exception:
                message = ("无法完成本机识别，请重新框选或检查安装。" if operation == "ocr"
                           else "无法完成翻译，请检查翻译服务或重试。")
                self.results.put(("", message))
            else:
                self.results.put((result, ""))

        Thread(target=worker, daemon=True).start()
        self.after(40, self.receive, operation)

    def receive(self, operation):
        try:
            result, error = self.results.get_nowait()
        except Empty:
            self.after(40, self.receive, operation)
            return
        self.busy = False
        self.original.configure(state="normal")
        if error:
            self.status.set(error)
        elif operation == "ocr":
            if result:
                self.original.insert("1.0", result)
                self.original.edit_reset()
                self.original.edit_modified(False)
                self.status.set("已识别，可以修改原文。")
                if self.winfo_ismapped():
                    self.original.focus_set()
            else:
                self.status.set("选区内没有识别到文字，请重新框选。")
        else:
            self.show_translation(result)
            self.status.set("翻译完成。")
        self.sync_buttons()
