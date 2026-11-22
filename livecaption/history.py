"""Read, save, and export current and archived subtitles in a separate window."""

import tkinter as tk
from datetime import datetime
from tkinter import ttk

import theme


class CaptionHistory(tk.Toplevel):
    def __init__(self, parent, recall_anchor, select_session, save_session, export_session):
        super().__init__(parent, bg=theme.BACKGROUND)
        self.title("字幕回看")
        self.transient(parent)
        scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        width = min(round(550 * scale), self.winfo_screenwidth() - 32)
        height = min(round(390 * scale), self.winfo_screenheight() - 82)
        self.geometry(f"{width}x{height}")
        self.minsize(min(round(365 * scale), width), min(round(220 * scale), height))
        self.bind("<Escape>", lambda _event: self.destroy())
        self.bind("<Map>", self.color_frame)
        self.entries = {}
        self.recall_anchor = recall_anchor
        self.reading_recap = False
        self.saved_transcript = None
        self.session_ids = (None,)
        self.session_description = ""

        content = ttk.Frame(self, padding=(12, 9, 8, 9), style="Panel.TFrame")
        content.pack(fill="both", expand=True, padx=theme.SPACE * 2, pady=theme.SPACE * 2)
        content.rowconfigure(2, weight=1)
        content.columnconfigure(0, weight=1)
        # Reserve the same wrap width whether or not the scrollbar is present.
        content.columnconfigure(1, minsize=16)
        toolbar = ttk.Frame(content, style="Panel.TFrame")
        toolbar.grid(row=0, columnspan=2, sticky="ew", pady=(0, 5))
        toolbar.columnconfigure(0, weight=1)
        self.session_picker = ttk.Combobox(toolbar, width=1, height=8, state="readonly")
        self.session_picker.grid(row=0, column=0, sticky="ew", padx=(0, 8))
        self.session_picker.bind("<<ComboboxSelected>>",
                                 lambda _event: select_session(self.session_ids[self.session_picker.current()]))
        self.save_button = ttk.Button(toolbar, text="保存本场", style="PanelQuiet.TButton", command=save_session)
        self.save_button.grid(row=0, column=1, padx=(0, 4))
        self.export_button = ttk.Button(toolbar, text="导出…", style="PanelQuiet.TButton", command=export_session)
        self.export_button.grid(row=0, column=2)

        self.session_label = ttk.Label(content, style="PanelHint.TLabel")
        self.session_label.grid(row=1, columnspan=2, sticky="ew", padx=6, pady=(0, 4))
        self.session_label.bind("<Configure>", lambda event: self.session_label.configure(wraplength=event.width))
        self.text = tk.Text(content, wrap="word", bg=theme.PANEL, fg=theme.TEXT,
                            selectbackground=theme.ACCENT, selectforeground=theme.BUTTON_TEXT,
                            font=(theme.FONT, 11), bd=0, highlightthickness=0, padx=6, pady=7,
                            spacing1=1, spacing2=4, spacing3=1)
        self.scrollbar = ttk.Scrollbar(content, command=self.text.yview, style="History.Vertical.TScrollbar")
        self.scrollbar.grid(row=2, column=1, sticky="nse", pady=4)
        self.scrollbar.grid_remove()

        navigation = ttk.Frame(content, style="Panel.TFrame")
        navigation.grid(row=3, columnspan=2, sticky="ew", pady=(4, 0))
        navigation.columnconfigure(0, weight=1)
        self.recent = ttk.Button(navigation, text="刚才 30 秒", style="PanelQuiet.TButton", command=self.go_recent)
        self.recent.grid(row=0, column=0, sticky="w")
        self.latest = ttk.Button(navigation, text="回到最新 ↓", style="PanelQuiet.TButton", command=self.go_latest)
        self.latest.grid(row=0, column=1, sticky="e")
        self.latest.grid_remove()
        self.text.configure(yscrollcommand=self.scroll_changed)
        self.text.tag_configure("empty", foreground=theme.MUTED)
        self.text.mark_set("reading", "1.0")
        self.text.mark_gravity("reading", "left")
        self.text.grid(row=2, column=0, sticky="nsew")
        self.reset({})
        self.text.focus_set()

    @property
    def archive_id(self):
        if self.saved_transcript is not None:
            return self.saved_transcript.ident

    def show_sessions(self, saved, current_id):
        archived = [(ident, started) for ident, started in saved.items() if ident != current_id]
        archived.sort(key=lambda item: item[1], reverse=True)
        self.session_ids = (None, *(ident for ident, _ in archived))
        labels = [datetime.fromtimestamp(started).strftime("%Y-%m-%d %H:%M:%S") for _, started in archived]
        self.session_picker.configure(values=("本场字幕", *labels), state="readonly" if archived else "disabled")
        selected = self.archive_id
        self.session_picker.current(self.session_ids.index(selected) if selected in self.session_ids else 0)

    def show_notice(self, message=""):
        label = " · ".join(part for part in (self.session_description, message) if part)
        if label:
            self.session_label.configure(text=label)
            self.session_label.grid()
        else:
            self.session_label.grid_remove()

    def update_actions(self):
        has_entries = bool(self.entries)
        current = self.saved_transcript is None
        self.save_button.state(["!disabled"] if current and has_entries else ["disabled"])
        self.export_button.state(["!disabled"] if has_entries else ["disabled"])
        if current:
            self.recent.grid()
            self.recent.state(["!disabled"] if has_entries else ["disabled"])
        else:
            self.recent.grid_remove()

    def scroll_changed(self, first, last):
        self.scrollbar.set(first, last)
        at_end = float(last) >= 1.0
        if float(first) == 0.0 and at_end:
            self.scrollbar.grid_remove()
        elif not self.scrollbar.winfo_manager():
            self.scrollbar.grid()
        if self.saved_transcript is not None or (at_end and not self.reading_recap):
            self.latest.grid_remove()
        elif not self.latest.winfo_manager():
            self.latest.grid()

    def go_recent(self):
        anchor = self.entries.get(self.recall_anchor())
        if anchor is not None:
            self.reading_recap = True
            self.text.yview(anchor[0])
            self.scroll_changed(*self.text.yview())
            self.text.focus_set()

    def go_latest(self):
        self.reading_recap = False
        self.text.see("end-1c")
        self.scroll_changed(*self.text.yview())
        self.text.focus_set()

    def color_frame(self, event):
        if event.widget is self:
            theme.color_title_bar(self)

    def reset(self, entries, record=None, *, archived=False):
        self.reading_recap = False
        self.saved_transcript = record if archived else None
        if record is None:
            self.session_description = ""
        else:
            started = datetime.fromtimestamp(record.started_at).strftime("%m-%d %H:%M")
            self.session_description = f"已保存于本机 · {started}" if archived else f"本场开始于 {started}"
        self.show_notice()
        self.text.configure(state="normal")
        if self.entries:
            self.text.mark_unset(*(mark for pair in self.entries.values() for mark in pair))
        self.entries.clear()
        self.text.delete("1.0", "end")
        if entries:
            for ident, text in entries.items():
                self.append(ident, text)
        else:
            self.text.insert("end-1c", "暂无字幕。开始翻译后，译文会显示在这里。", "empty")
        self.text.configure(state="disabled")
        self.text.see("1.0" if archived else "end-1c")
        self.update_actions()
        self.scroll_changed(*self.text.yview())

    def append(self, ident, text):
        entry = len(self.entries)
        if self.entries:
            self.text.insert("end-1c", "\n\n")
        first, last = f"caption{entry}_start", f"caption{entry}_end"
        self.text.mark_set(first, "end-1c")
        self.text.mark_gravity(first, "left")
        self.text.insert("end-1c", text)
        self.text.mark_set(last, "end-1c")
        self.text.mark_gravity(last, "left")
        self.entries[ident] = first, last

    def update_line(self, ident, text):
        follow = not self.reading_recap and self.text.yview()[1] >= 1.0
        if not follow:
            self.text.mark_set("reading", "@0,0")
        self.text.configure(state="normal")
        if ident in self.entries:
            first, last = self.entries[ident]
            if self.text.get(first, last) != text:
                self.text.mark_gravity(last, "right")
                self.text.replace(first, last, text)
                self.text.mark_gravity(last, "left")
        else:
            if not self.entries:
                self.text.delete("1.0", "end")
            self.append(ident, text)
            if len(self.entries) == 1:
                self.update_actions()
        self.text.configure(state="disabled")
        if follow:
            self.text.see("end-1c")
        elif self.text.compare("@0,0", "!=", "reading"):
            self.text.yview("reading")
