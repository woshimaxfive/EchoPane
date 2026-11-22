"""Controls displayed with the hovered caption surface."""

from tkinter import ttk

from preferences import CAPTION_SIZES


class CaptionControls(ttk.Frame):
    def __init__(self, parent, change_size, change_background, toggle_lock, stop, dismiss):
        super().__init__(parent, style="Dock.TFrame")
        self.smaller = self.add_button("A−", lambda: change_size(-1))
        self.size_label = ttk.Label(self, style="DockValue.TLabel", width=2, anchor="center")
        self.size_label.pack(side="left")
        self.larger = self.add_button("A+", lambda: change_size(1))
        self.background_button = self.add_button("加底色", change_background)
        self.lock_button = self.add_button("锁定", toggle_lock)
        self.stop_button = self.add_button("停止", stop)
        self.stop_button.pack_forget()
        self.close_button = self.add_button("×", dismiss)
        self.drag_surfaces = (self, self.size_label)

    def add_button(self, text, command):
        button = ttk.Button(self, text=text, command=command, style="Dock.TButton", cursor="hand2")
        button.pack(side="left", padx=1)
        return button

    def sync(self, size, background, locked):
        self.size_label.configure(text=str(size))
        self.smaller.state(["disabled"] if size == CAPTION_SIZES[0] else ["!disabled"])
        self.larger.state(["disabled"] if size == CAPTION_SIZES[-1] else ["!disabled"])
        self.background_button.configure(text="去底色" if background == "shade" else "加底色")
        self.lock_button.configure(text="解锁" if locked else "锁定")

    def set_active(self, active):
        if active:
            self.stop_button.state(["!disabled"])
            self.stop_button.pack(side="left", padx=1, before=self.close_button)
        else:
            self.stop_button.pack_forget()
