"""Edit preferred translations in a small settings window."""

import tkinter as tk
from tkinter import ttk

import theme
from glossary import MAX_TERMS
from views import wrap_label
from window_frame import WindowPosition


class GlossarySettings(tk.Toplevel):
    def __init__(self, parent, terms, save_terms):
        super().__init__(parent, bg=theme.BACKGROUND)
        self.withdraw()
        self.title("术语词表")
        self.transient(parent)
        self.bind("<Escape>", lambda _event: self.destroy())
        self.bind("<Map>", self.color_frame)
        self.terms = terms
        self.save_terms = save_terms

        body = ttk.Frame(self, padding=(16, 13), style="Panel.TFrame")
        body.pack(fill="both", expand=True, padx=12, pady=12)
        body.columnconfigure(0, weight=1)
        body.rowconfigure(1, weight=1)
        intro = ttk.Label(body, text="保存常用的人名、地名和术语。新翻译任务会把相关词条交给百炼，"
                          "实时字幕开始时会提交整份词表作为译法参考。", style="PanelHint.TLabel")
        intro.grid(row=0, sticky="ew", pady=(0, 9))
        wrap_label(intro)

        list_panel = ttk.Frame(body, style="PanelInner.TFrame")
        list_panel.grid(row=1, sticky="nsew")
        list_panel.columnconfigure(0, weight=1)
        list_panel.rowconfigure(0, weight=1)
        self.table = ttk.Treeview(list_panel, columns=("source", "target"), show="headings", height=6,
                                  style="Usage.Treeview", selectmode="browse")
        self.table.grid(row=0, column=0, sticky="nsew")
        self.table.heading("source", text="原文术语", anchor="w")
        self.table.heading("target", text="指定译法", anchor="w")
        scroll = ttk.Scrollbar(list_panel, orient="vertical", command=self.table.yview)
        scroll.grid(row=0, column=1, sticky="ns")
        self.table.configure(yscrollcommand=scroll.set)
        self.table.bind("<<TreeviewSelect>>", self.choose_term)

        form = ttk.Frame(body, style="PanelInner.TFrame")
        form.grid(row=2, sticky="ew", pady=(12, 0))
        self.source = tk.StringVar(self)
        self.target = tk.StringVar(self)
        for column, (label, value) in enumerate((("原文术语", self.source), ("指定译法", self.target))):
            form.columnconfigure(column, weight=1, uniform="term")
            ttk.Label(form, text=label, style="Panel.TLabel").grid(row=0, column=column, sticky="w")
            entry = ttk.Entry(form, textvariable=value, width=1)
            entry.grid(row=1, column=column, sticky="ew", padx=(0, 8 if column == 0 else 0), pady=(4, 0))
            if column == 0:
                self.source_entry = entry
            entry.bind("<Return>", lambda _event: self.save_term())

        controls = ttk.Frame(body, style="PanelInner.TFrame")
        controls.grid(row=3, sticky="ew", pady=(10, 0))
        ttk.Button(controls, text="新建", style="PanelQuiet.TButton", command=self.new_term).pack(side="left")
        self.remove_button = ttk.Button(controls, text="删除所选", style="PanelQuiet.TButton", command=self.remove_term)
        self.remove_button.pack(side="left", padx=5)
        self.save_button = ttk.Button(controls, text="添加术语", style="Primary.TButton", command=self.save_term)
        self.save_button.pack(side="right")
        self.notice = tk.StringVar(self, value=f"已保存 {len(terms)} 条 · 上限 {MAX_TERMS} 条")
        feedback = ttk.Label(body, textvariable=self.notice, style="PanelHint.TLabel")
        feedback.grid(row=4, sticky="ew", pady=(7, 0))
        wrap_label(feedback)

        scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        width = min(round(560 * scale), self.winfo_screenwidth() - 32)
        self.update_idletasks()
        self.minsize(min(round(440 * scale), width), self.winfo_reqheight())
        self.geometry(f"{width}x{self.winfo_reqheight()}")
        self.show_terms()
        WindowPosition(self, "glossary")
        self.deiconify()

    def color_frame(self, event):
        if event.widget is self:
            theme.color_title_bar(self)

    def show_terms(self):
        self.table.delete(*self.table.get_children())
        for index, pair in enumerate(self.terms):
            self.table.insert("", "end", iid=str(index), values=pair)
        self.new_term()

    def new_term(self):
        self.table.selection_remove(*self.table.selection())
        self.source.set("")
        self.target.set("")
        self.choose_term()
        self.source_entry.focus_set()

    def choose_term(self, _event=None):
        selected = self.table.selection()
        if selected:
            source, target = self.terms[int(selected[0])]
            self.source.set(source)
            self.target.set(target)
        self.save_button.configure(text="更新所选" if selected else "添加术语")
        self.remove_button.state(["!disabled"] if selected else ["disabled"])

    def save_term(self):
        rows = list(self.terms)
        pair = self.source.get(), self.target.get()
        selected = self.table.selection()
        if selected:
            rows[int(selected[0])] = pair
        else:
            rows.append(pair)
        self.apply(rows, "已保存")

    def remove_term(self):
        selected = self.table.selection()
        if selected:
            rows = list(self.terms)
            del rows[int(selected[0])]
            self.apply(rows, "已删除")

    def apply(self, rows, message):
        try:
            self.terms = self.save_terms(rows)
        except ValueError as exc:
            self.notice.set(str(exc))
        except OSError:
            self.notice.set("写入词表失败，请检查本机配置目录后重试。")
        else:
            self.show_terms()
            self.notice.set(f"{message} · {len(self.terms)} 条术语")
