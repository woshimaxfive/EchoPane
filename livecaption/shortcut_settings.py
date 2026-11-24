"""Edit and record shortcuts in the focused settings window."""

import tkinter as tk
from functools import partial
from tkinter import ttk

import theme
from shortcuts import MOD_ALT, MOD_CONTROL, MOD_SHIFT, SHORTCUTS, parse_shortcut, shortcut_for_key
from window_frame import WindowPosition


# Tk's Windows keyboard event uses X-style Shift and Control bits and Tk's Alt bit.
TK_SHIFT = 0x0001
TK_CONTROL = 0x0004
TK_ALT = 0x20000


class ShortcutSettings(tk.Toplevel):
    def __init__(self, parent, shortcuts):
        super().__init__(parent, bg=theme.BACKGROUND)
        self.withdraw()
        self.title("快捷键")
        self.transient(parent)
        self.resizable(False, False)
        self.bind("<Escape>", self.escape)
        self.bind("<Map>", self.color_frame)
        self.shortcuts = shortcuts
        self.recording = None
        self.inputs = {}
        self.values = {}
        self.record_buttons = {}
        self.notice = tk.StringVar(self)

        scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        width = min(round(480 * scale), self.winfo_screenwidth() - 32)
        body = ttk.Frame(self, padding=(16, 13), style="Panel.TFrame")
        body.pack(fill="both", expand=True, padx=12, pady=12)
        body.columnconfigure(1, weight=1)
        ttk.Label(body, text="全局快捷键", style="PanelSection.TLabel").grid(row=0, columnspan=4, sticky="w")
        ttk.Label(body, text="点录制后按组合键，也可直接输入，例如 Ctrl+Shift+K。",
                  style="PanelHint.TLabel", wraplength=width - 60).grid(
            row=1, columnspan=4, sticky="ew", pady=(4, 8)
        )
        for row, (name, (label, _default)) in enumerate(SHORTCUTS.items(), 2):
            ttk.Label(body, text=label, style="Panel.TLabel").grid(row=row, column=0, sticky="w", padx=(0, 10))
            value = self.values[name] = tk.StringVar(self)
            entry = self.inputs[name] = ttk.Entry(body, textvariable=value, width=1)
            entry.grid(row=row, column=1, sticky="ew", pady=4)
            entry.bind("<KeyPress>", self.record_key)
            entry.bind("<FocusOut>", self.record_focus_out)
            self.record_buttons[name] = ttk.Button(body, text="录制", width=7, style="PanelQuiet.TButton",
                                                    command=partial(self.begin_recording, name))
            self.record_buttons[name].grid(row=row, column=2, padx=(6, 0))
            ttk.Button(body, text="停用", style="PanelQuiet.TButton", command=partial(self.disable, name)).grid(
                row=row, column=3
            )

        status_row = len(SHORTCUTS) + 2
        body.rowconfigure(status_row, minsize=round(44 * scale))
        ttk.Label(body, textvariable=self.notice, style="PanelHint.TLabel", wraplength=width - 60).grid(
            row=status_row, columnspan=4, sticky="ew", pady=(5, 4)
        )
        self.defaults_button = ttk.Button(body, text="恢复默认", style="PanelQuiet.TButton", command=self.restore)
        self.defaults_button.grid(row=status_row + 1, columnspan=2, sticky="w")
        self.save_button = ttk.Button(body, text="保存", style="Primary.TButton", command=self.save)
        self.save_button.grid(row=status_row + 1, column=2, columnspan=2, sticky="e")
        self.show_saved()
        self.update_idletasks()
        self.geometry(f"{width}x{self.winfo_reqheight()}")
        WindowPosition(self, "shortcuts")
        self.deiconify()

    def color_frame(self, event):
        if event.widget is self:
            theme.color_title_bar(self)

    def show_saved(self, message="留空即停用。"):
        unavailable = []
        for name, chord in self.shortcuts.bindings.items():
            self.values[name].set(str(chord) if chord is not None else "")
            if chord is not None and not self.shortcuts.available(name):
                unavailable.append(SHORTCUTS[name][0])
        if unavailable:
            labels = "、".join(f"「{label}」" for label in unavailable)
            message = f"{message} {labels}当前不可用，可换一个组合。"
        self.notice.set(message)

    def begin_recording(self, name):
        self.stop_recording()
        self.recording = name
        self.shortcuts.recorder = self.accept_chord
        self.record_buttons[name].configure(text="录制中")
        self.inputs[name].focus_set()
        self.notice.set("请按下想用的组合键，Esc 取消录制。")

    def stop_recording(self):
        if self.recording is not None:
            self.record_buttons[self.recording].configure(text="录制")
            self.recording = None
            self.shortcuts.recorder = None
            self.notice.set("留空即停用。")

    def record_focus_out(self, event):
        if self.recording is not None and self.inputs[self.recording] is event.widget:
            self.stop_recording()

    def record_key(self, event):
        if self.recording is None:
            return
        key = event.keycode
        if key in (0x10, 0x11, 0x12):
            return "break"
        modifiers = (MOD_CONTROL if event.state & TK_CONTROL else 0)
        modifiers |= MOD_ALT if event.state & TK_ALT else 0
        modifiers |= MOD_SHIFT if event.state & TK_SHIFT else 0
        if key == 0x1B and not modifiers:
            self.stop_recording()
            return "break"
        try:
            chord = shortcut_for_key(modifiers, key)
        except ValueError as exc:
            self.notice.set(str(exc))
        else:
            self.accept_chord(chord)
        return "break"

    def accept_chord(self, chord):
        name = self.recording
        if name is None or self.focus_get() is not self.inputs[name]:
            return False
        self.stop_recording()
        self.values[name].set(str(chord))
        self.notice.set("组合已录入，保存后生效。")
        return True

    def disable(self, name):
        self.stop_recording()
        self.values[name].set("")
        self.notice.set(f"保存后停用「{SHORTCUTS[name][0]}」的快捷键。")

    def restore(self):
        self.stop_recording()
        for name, (_label, default) in SHORTCUTS.items():
            self.values[name].set(default)
        self.notice.set("默认组合已填入，保存后生效。")

    def save(self):
        self.stop_recording()
        bindings = {}
        for name, value in self.values.items():
            try:
                bindings[name] = parse_shortcut(value.get())
            except ValueError as exc:
                self.notice.set(str(exc))
                self.inputs[name].focus_set()
                return
        try:
            self.shortcuts.apply(bindings)
        except ValueError as exc:
            self.notice.set(str(exc))
        except OSError:
            self.notice.set("无法写入本机设置，当前快捷键仍然可用。")
        else:
            self.show_saved("已保存，快捷键立即生效。")

    def escape(self, _event):
        if self.recording is not None:
            self.stop_recording()
        else:
            self.destroy()
        return "break"

    def destroy(self):
        self.stop_recording()
        super().destroy()
