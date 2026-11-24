"""Read, save, and export current and archived subtitles in a separate window."""

import tkinter as tk
from datetime import datetime
from functools import partial
from tkinter import ttk

import theme
from window_frame import WindowPosition


class CaptionHistory(tk.Toplevel):
    def __init__(self, parent, recall_anchor, select_session, save_session, export_session):
        super().__init__(parent, bg=theme.BACKGROUND)
        self.withdraw()
        self.title("字幕回看")
        self.transient(parent)
        scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        width = min(round(550 * scale), self.winfo_screenwidth() - 32)
        height = min(round(425 * scale), self.winfo_screenheight() - 82)
        self.geometry(f"{width}x{height}")
        self.minsize(min(round(365 * scale), width), min(round(290 * scale), height))
        self.bind("<Escape>", lambda _event: self.destroy())
        self.bind("<Map>", self.color_frame)
        self.entries = {}
        self.recall_anchor = recall_anchor
        self.reading_recap = False
        self.saved_transcript = None
        self.session_ids = (None,)
        self.session_description = ""
        self.query = tk.StringVar(self)
        self.match_lengths = tk.Variable(self)
        self.search_status = tk.StringVar(self)
        self.matches = ()
        self.match_index = None
        self.search_refresh = None

        content = ttk.Frame(self, padding=(12, 9, 8, 9), style="Panel.TFrame")
        content.pack(fill="both", expand=True, padx=theme.SPACE * 2, pady=theme.SPACE * 2)
        content.rowconfigure(3, weight=1)
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

        search = ttk.Frame(content, style="Panel.TFrame")
        search.grid(row=1, columnspan=2, sticky="ew", pady=(0, 5))
        search.columnconfigure(1, weight=1)
        ttk.Label(search, text="查找本场", style="Panel.TLabel").grid(row=0, column=0, padx=(0, 7))
        self.search_entry = ttk.Entry(search, textvariable=self.query, width=1)
        self.search_entry.grid(row=0, column=1, sticky="ew")
        ttk.Label(search, textvariable=self.search_status, style="PanelHint.TLabel", width=10, anchor="center").grid(
            row=0, column=2
        )
        self.previous_match = ttk.Button(search, text="上一处", style="PanelQuiet.TButton",
                                         command=partial(self.step_match, -1))
        self.next_match = ttk.Button(search, text="下一处", style="PanelQuiet.TButton",
                                     command=partial(self.step_match, 1))
        self.previous_match.grid(row=0, column=3)
        self.next_match.grid(row=0, column=4)
        self.bind("<Control-f>", self.focus_search)
        self.search_entry.bind("<Return>", partial(self.step_match, 1))
        self.search_entry.bind("<Shift-Return>", partial(self.step_match, -1))
        self.search_entry.bind("<Escape>", self.clear_search)

        self.session_label = ttk.Label(content, style="PanelHint.TLabel")
        self.session_label.grid(row=2, columnspan=2, sticky="ew", padx=6, pady=(0, 4))
        self.session_label.bind("<Configure>", lambda event: self.session_label.configure(wraplength=event.width))
        self.text = tk.Text(content, wrap="word", bg=theme.PANEL, fg=theme.TEXT,
                            selectbackground=theme.ACCENT, selectforeground=theme.BUTTON_TEXT,
                            font=(theme.FONT, 11), bd=0, highlightthickness=0, padx=6, pady=7,
                            spacing1=1, spacing2=4, spacing3=1)
        self.scrollbar = ttk.Scrollbar(content, command=self.text.yview, style="History.Vertical.TScrollbar")
        self.scrollbar.grid(row=3, column=1, sticky="nse", pady=4)
        self.scrollbar.grid_remove()

        navigation = ttk.Frame(content, style="Panel.TFrame")
        navigation.grid(row=4, columnspan=2, sticky="ew", pady=(4, 0))
        navigation.columnconfigure(0, weight=1)
        self.recent = ttk.Button(navigation, text="刚才 30 秒", style="PanelQuiet.TButton", command=self.go_recent)
        self.recent.grid(row=0, column=0, sticky="w")
        self.latest = ttk.Button(navigation, text="回到最新 ↓", style="PanelQuiet.TButton", command=self.go_latest)
        self.latest.grid(row=0, column=1, sticky="e")
        self.latest.grid_remove()
        self.text.configure(yscrollcommand=self.scroll_changed)
        self.text.tag_configure("empty", foreground=theme.MUTED)
        self.text.tag_configure("search_match", background=theme.ACCENT_PALE)
        self.text.tag_configure("current_match", background=theme.ACCENT, foreground=theme.BUTTON_TEXT)
        self.text.tag_raise("sel")
        self.text.mark_set("reading", "1.0")
        self.text.mark_gravity("reading", "left")
        self.text.grid(row=3, column=0, sticky="nsew")
        self.query.trace_add("write", lambda *_args: self.refresh_matches(jump=True))
        self.reset({})
        WindowPosition(self, "history")
        self.deiconify()
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

    def focus_search(self, _event):
        self.search_entry.focus_set()
        self.search_entry.selection_range(0, "end")
        return "break"

    def clear_search(self, _event):
        if self.query.get():
            self.query.set("")
            return "break"

    def refresh_matches(self, *, jump=False):
        if self.search_refresh is not None:
            self.after_cancel(self.search_refresh)
            self.search_refresh = None
        active = self.text.tag_ranges("current_match")
        self.text.tag_remove("search_match", "1.0", "end")
        self.text.tag_remove("current_match", "1.0", "end")
        query = self.query.get().strip()
        self.matches = ()
        self.match_index = None
        if query and self.entries:
            matches = self.tk.call(
                self.text, "search", "-all", "-exact", "-nocase", "-count", self.match_lengths,
                "--", query, "1.0", "end-1c",
            )
            starts = tuple(map(str, self.tk.splitlist(matches)))
            if starts:
                sizes = self.tk.splitlist(self.match_lengths.get())
                self.matches = tuple((start, f"{start} + {size} chars") for start, size in zip(starts, sizes))
                self.text.tag_add("search_match", *(index for match in self.matches for index in match))
                if jump:
                    self.show_match(0)
                elif active and str(active[0]) in starts:
                    self.match_index = starts.index(str(active[0]))
                    self.text.tag_add("current_match", *self.matches[self.match_index])
        self.update_match_controls(query)

    def update_match_controls(self, query):
        state = "!disabled" if self.matches else "disabled"
        self.previous_match.state([state])
        self.next_match.state([state])
        if self.match_index is not None:
            self.search_status.set(f"{self.match_index + 1} / {len(self.matches)}")
        elif self.matches:
            self.search_status.set(f"{len(self.matches)} 处匹配")
        else:
            self.search_status.set("无匹配" if query else "")

    def show_match(self, index):
        self.match_index = index
        first, last = self.matches[index]
        self.text.tag_remove("current_match", "1.0", "end")
        self.text.tag_add("current_match", first, last)
        self.reading_recap = True
        self.text.see(first)
        self.scroll_changed(*self.text.yview())

    def step_match(self, step, _event=None):
        if self.search_refresh is not None:
            self.refresh_matches()
        if self.matches:
            index = self.match_index
            if index is None:
                index = 0 if step < 0 else -1
            self.show_match((index + step) % len(self.matches))
            self.update_match_controls(self.query.get().strip())
        return "break"

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
            self.text.insert("end-1c", "暂无字幕。开始字幕后，内容会显示在这里。", "empty")
        self.text.configure(state="disabled")
        self.text.see("1.0" if archived else "end-1c")
        self.update_actions()
        self.scroll_changed(*self.text.yview())
        self.refresh_matches(jump=True)

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
        existing = self.entries.get(ident)
        if existing and self.text.get(*existing) == text:
            return
        follow = not self.reading_recap and self.text.yview()[1] >= 1.0
        if not follow:
            self.text.mark_set("reading", "@0,0")
        self.text.configure(state="normal")
        if existing:
            first, last = existing
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
        if self.search_refresh is None and self.query.get().strip():
            self.search_refresh = self.after_idle(self.refresh_matches)

    def destroy(self):
        if self.search_refresh is not None:
            self.after_cancel(self.search_refresh)
        super().destroy()
