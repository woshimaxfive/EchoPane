"""Shared colors, typography and widgets for the Windows interface."""

import ctypes
import sys
import time
import tkinter as tk
from pathlib import Path
from tkinter import font, ttk

from native_windows import animations_enabled
from surfaces import rounded_pixels


BACKGROUND = "#fafbfd"
RAIL = "#eef2f6"
HEADER = RAIL
PANEL = "#ffffff"
STATUS_BACKGROUND = "#f2f5f8"
FIELD = "#f9fbfd"
BORDER = "#dce4ed"
TEXT = "#202c39"
MUTED = "#526172"
ACCENT = "#2c5e8d"
ACCENT_HOVER = "#234f79"
ACCENT_PALE = "#e3edf8"
ACCENT_BORDER = "#c8d8eb"
ACCENT_PRESSED = "#193b60"
BUTTON_TEXT = "#ffffff"
WARNING = "#90561b"
READY = "#27806f"
METER_IDLE = "#dce5f2"
CAPTION_BG = "#1c2431"
CAPTION_TEXT = "#fafbff"
CAPTION_PREVIOUS = "#dbe3ef"
CAPTION_GOLD = "#efd1a5"
CAPTION_EDIT = "#d1e1fa"
CAPTION_STROKE = "#101620"
CAPTION_KEY = "#27292b"
CAPTION_HOVER = "#3c4e66"
DOCK_COLOR = "#182535"
DOCK_TRAY = "#25364b"
DOCK_MUTED = "#adbdd4"
DOCK_RIM = "#71849c"
DOCK_PRESSED = "#304b67"
DOCK_OPACITY = 0.74
FONT = "Microsoft YaHei UI"
SPACE = 8
GUTTER = 23
PANEL_RADIUS = 15
CONTROL_RADIUS = 9
DOCK_RADIUS = 19
HEADER_HEIGHT = 40
TAB_MARGIN = (10, 12, 8, 0)
TAB_PADDING = (10, 5, 10, 5)
TAB_SURFACE_PADDING = 3
TAB_TEXT_GAP = 8
TAB_STYLE = "Workspace.TNotebook"
COMPACT_TAB_STYLE = f"Compact.{TAB_STYLE}"

GLYPHS = {
    "live": ((1, 2, 15, 3), (1, 3, 2, 12), (14, 3, 15, 12), (1, 12, 15, 13),
             (6, 5, 7, 10), (7, 6, 9, 9), (9, 7, 11, 8)),
    "captions": ((1, 2, 15, 3), (1, 3, 2, 12), (14, 3, 15, 12), (1, 12, 15, 13),
                 (4, 6, 10, 7), (4, 9, 12, 10)),
    "screen": ((1, 2, 6, 3), (1, 3, 2, 6), (10, 2, 15, 3), (14, 3, 15, 6),
               (1, 10, 2, 13), (1, 13, 6, 14), (14, 10, 15, 13), (10, 13, 15, 14),
               (5, 6, 11, 7), (5, 9, 9, 10)),
    "usage": ((1, 2, 2, 14), (1, 13, 15, 14), (4, 8, 6, 12), (8, 5, 10, 12), (12, 2, 14, 12)),
    "settings": ((2, 3, 14, 4), (5, 2, 7, 5), (2, 7, 14, 8), (10, 6, 12, 9),
                 (2, 11, 14, 12), (6, 10, 8, 13)),
    "play": ((5, 3, 6, 13), (6, 4, 8, 12), (8, 5, 10, 11), (10, 6, 12, 10), (12, 7, 13, 9)),
    "stop": ((4, 4, 12, 12),),
    "collapse": ((2, 7, 4, 9), (3, 6, 5, 8), (4, 5, 6, 7), (5, 4, 7, 6),
                 (3, 8, 5, 10), (4, 9, 6, 11), (5, 10, 7, 12),
                 (8, 7, 10, 9), (9, 6, 11, 8), (10, 5, 12, 7), (11, 4, 13, 6),
                 (9, 8, 11, 10), (10, 9, 12, 11), (11, 10, 13, 12)),
    "minimize": ((3, 8, 13, 9),),
    "maximize": ((3, 3, 13, 4), (3, 12, 13, 13), (3, 4, 4, 12), (12, 4, 13, 12)),
    "restore": ((5, 2, 14, 3), (13, 3, 14, 11), (11, 10, 13, 11),
                (2, 5, 11, 6), (2, 13, 11, 14), (2, 6, 3, 13), (10, 6, 11, 13)),
    "close": tuple((x, y, x + 1, y + 1) for x in range(4, 12) for y in (x, 15 - x)),
}
GLYPHS["expand"] = tuple((16 - right, top, 16 - left, bottom)
                         for left, top, right, bottom in GLYPHS["collapse"])


def asset_path(name):
    app_dir = Path(sys.executable if getattr(sys, "frozen", False) else __file__).resolve().parent
    return app_dir / "assets" / name


def secondary_caption_size(size):
    return max(12, round(size * 0.72))


def glyph(root, name, color, *, min_height=0):
    scale = max(1.0, float(root.tk.call("tk", "scaling")) * 0.75)
    size = round(16 * scale)
    height = max(size, min_height)
    offset = (height - size) // 2
    image = tk.PhotoImage(master=root, width=size, height=height)
    for box in GLYPHS[name]:
        left, top, right, bottom = (round(edge * scale) for edge in box)
        image.put(color, to=(left, top + offset, right, bottom + offset))
    return image


class Transition:
    """Move from the last drawn value so a new target can interrupt the motion."""

    def __init__(self, scheduler, draw):
        self.scheduler = scheduler
        self.draw = draw
        self.enabled = animations_enabled()
        self.value = self.target = 0.0
        self.job = None

    def move_to(self, target, *, immediate=False):
        if target == self.target and not immediate:
            return
        self.cancel()
        self.target = target
        if immediate or not self.enabled or target == self.value:
            self.value = target
            self.draw(target)
            return

        start = self.value
        started = time.perf_counter()

        def step():
            self.job = None
            progress = min(1.0, (time.perf_counter() - started) / 0.16)
            eased = 1 - (1 - progress) ** 3
            self.value = start + (target - start) * eased
            self.draw(self.value)
            if progress < 1:
                self.job = self.scheduler.after(16, step)

        self.job = self.scheduler.after(16, step)

    def cancel(self):
        if self.job is not None:
            self.scheduler.after_cancel(self.job)
            self.job = None


class WindowHeader(tk.Frame):
    """Share the app's top row with the sidebar and the window controls."""

    def __init__(self, window, scale):
        self.height = round(HEADER_HEIGHT * scale)
        super().__init__(window, height=self.height, bg=BACKGROUND)
        self.window = window
        self.rail = tk.Frame(self, bg=RAIL)
        self.rail_edge = 0
        self.control_width = round(34 * scale)
        self.control_height = round(28 * scale)
        self.control_inset = round(7 * scale)

    def set_rail_width(self, width):
        self.rail_edge = width
        self.rail.place(x=0, y=0, width=width, relheight=1)

    def bind_drag(self, frame, *sidebar_surfaces):
        for surface in (self, self.rail, *sidebar_surfaces):
            surface.bind("<ButtonPress-1>", frame.begin_drag)
            surface.bind("<B1-Motion>", frame.drag)
            surface.bind("<ButtonRelease-1>", frame.finish_drag)
            surface.bind("<Double-ButtonPress-1>", lambda _event: self.toggle_maximize())

    def show_controls(self, close):
        self.icons = {name: glyph(self, name, MUTED) for name in ("minimize", "maximize", "restore", "close")}
        self.minimize = ttk.Button(self, style="Caption.TButton", compound="image", text="最小化",
                                   image=self.icons["minimize"], command=self.window.iconify)
        self.maximize = ttk.Button(self, style="Caption.TButton", compound="image", command=self.toggle_maximize)
        self.close = ttk.Button(self, style="CloseCaption.TButton", compound="image", text="关闭",
                                image=self.icons["close"], command=close)
        for index, button in enumerate((self.close, self.maximize, self.minimize), start=1):
            button.place(relx=1, rely=0.5, x=-self.control_inset - (index - 1) * self.control_width,
                         anchor="e", width=self.control_width, height=self.control_height)
        self.zoomed = None
        self.window.bind("<Configure>", self.sync_maximize, add="+")
        self.sync_maximize()

    def sync_maximize(self, event=None):
        if event is not None and event.widget is not self.window:
            return
        zoomed = self.window.state() == "zoomed"
        if self.zoomed != zoomed:
            self.zoomed = zoomed
            self.maximize.configure(text="还原" if zoomed else "最大化",
                                    image=self.icons["restore" if zoomed else "maximize"])

    def toggle_maximize(self):
        self.window.state("normal" if self.window.state() == "zoomed" else "zoomed")
        self.sync_maximize()


class Workspace(ttk.Notebook):
    """Keep native page navigation and switch between a labeled and an icon rail."""

    def __init__(self, parent, *, header, collapsed=False, on_toggle=None):
        super().__init__(parent, style=COMPACT_TAB_STYLE if collapsed else TAB_STYLE)
        self.enable_traversal()
        self.scale = max(1.0, float(self.tk.call("tk", "scaling")) * 0.75)
        self.margins = tuple(round(value * self.scale) for value in TAB_MARGIN)
        self.collapsed = collapsed
        self.on_toggle = on_toggle
        self.header = header
        self.rail_edge = 0
        self.nav_font = font.Font(root=self, family=FONT, size=10)
        self.nav_images = []
        self.marker_height = round(17 * self.scale)
        self.marker_strip = tk.Canvas(self, width=self.margins[0], bg=RAIL, bd=0, highlightthickness=0, takefocus=0)
        self.marker_strip.place(x=0, y=0, relheight=1)
        self.marker = self.marker_strip.create_line(0, 0, 0, 0, width=round(3 * self.scale),
                                                    fill=ACCENT, capstyle="round", state="hidden")
        self.divider = tk.Frame(self, bg=BORDER, width=1, takefocus=0)
        self.arrows = (glyph(self, "collapse", MUTED), glyph(self, "expand", MUTED))
        self.rail_divider = tk.Frame(header.rail, bg=BORDER, width=1, takefocus=0)
        self.rail_divider.place(relx=1, x=-1, y=0, relheight=1)
        self.brand = ttk.Label(header.rail, text="EchoPane", style="RailBrand.TLabel", takefocus=0)
        self.toggle_button = ttk.Button(header.rail, style="Rail.TButton", compound="image", command=self.toggle_sidebar)
        self.update_toggle()
        self.tip = ttk.Label(self, style="RailTip.TLabel", takefocus=0)
        self.tip_job = self.tip_text = None

        self.scheduler = self.winfo_toplevel()
        self.motion = Transition(self.scheduler, self.place_marker)
        self.marker_job = None
        self.bind("<<NotebookTabChanged>>", self.schedule_marker)
        self.bind("<Configure>", self.schedule_marker)
        self.bind("<Motion>", self.hover_tab, add="+")
        self.bind("<Leave>", self.hide_tip, add="+")
        self.bind("<ButtonPress-1>", self.hide_tip, add="+")
        self.toggle_button.bind("<Enter>", lambda event: self.queue_tip(
            self.toggle_button.cget("text"), self.toggle_button.winfo_rooty() - self.winfo_rooty() + event.y
        ))
        self.toggle_button.bind("<Leave>", self.hide_tip)

    def add_page(self, page, title, icon):
        height = self.nav_font.metrics("linespace")
        normal = glyph(self, icon, MUTED, min_height=height)
        selected = glyph(self, icon, ACCENT, min_height=height)
        self.nav_images.extend((normal, selected))
        self.add(page, text=title, image=(normal, "selected", selected),
                 compound="image" if self.collapsed else "left", sticky="nsew")
        page.bind("<Configure>", self.schedule_marker, add="+")
        # Equal-width tab surfaces also accommodate newly registered pages with longer names.
        inset = sum(round(value * self.scale) for value in (TAB_PADDING[0], TAB_PADDING[2]))
        inset += 2 * round(TAB_SURFACE_PADDING * self.scale)
        required = self.nav_font.measure(title) + normal.width() + round(TAB_TEXT_GAP * self.scale) + inset
        style = ttk.Style(self)
        if required > int(style.lookup(TAB_STYLE, "mintabwidth")):
            style.configure(TAB_STYLE, mintabwidth=required)

    def update_toggle(self):
        text = "展开侧栏" if self.collapsed else "收起侧栏"
        self.toggle_button.configure(text=text, image=self.arrows[int(self.collapsed)])

    def toggle_sidebar(self):
        self.hide_tip()
        self.collapsed = not self.collapsed
        self.configure(style=COMPACT_TAB_STYLE if self.collapsed else TAB_STYLE)
        compound = "image" if self.collapsed else "left"
        for tab in self.tabs():
            self.tab(tab, compound=compound)
        self.update_toggle()
        self.schedule_marker()
        if self.on_toggle is not None:
            self.on_toggle(self.collapsed)

    def hover_tab(self, event):
        if not self.collapsed:
            return
        index = self.tk.call(self._w, "identify", "tab", event.x, event.y)
        if index == "":
            self.hide_tip()
        else:
            self.queue_tip(self.tab(int(index), "text"), event.y)

    def queue_tip(self, text, y):
        if self.tip_text == text:
            return
        self.hide_tip()
        self.tip_text = text
        self.tip_job = self.after(420, self.show_tip, text, y)

    def show_tip(self, text, y):
        self.tip_job = None
        self.tip.configure(text=text)
        half = self.tip.winfo_reqheight() // 2
        y = max(half, min(y, self.winfo_height() - half))
        self.tip.place(x=self.rail_edge + round(7 * self.scale), y=y, anchor="w")
        self.tip.lift()

    def hide_tip(self, _event=None):
        if self.tip_job is not None:
            self.after_cancel(self.tip_job)
            self.tip_job = None
        self.tip_text = None
        self.tip.place_forget()

    def schedule_marker(self, _event=None):
        if self.marker_job is None:
            self.marker_job = self.scheduler.after_idle(self.sync_marker)

    def sync_marker(self):
        self.marker_job = None
        selected = self.select()
        if not selected:
            return
        left, top, right, _ = self.margins
        edge = self.nametowidget(selected).winfo_x()
        if edge <= left:
            return
        self.rail_edge = edge
        self.divider.place(x=edge - 1, y=0, relheight=1)
        self.header.set_rail_width(edge)
        if self.collapsed:
            self.brand.place_forget()
        else:
            self.brand.place(x=left + round(8 * self.scale), rely=0.5, anchor="w")
        toggle_width = self.toggle_button.winfo_reqwidth()
        toggle_x = (left + edge - right) / 2 if self.collapsed else edge - right - toggle_width / 2
        self.toggle_button.place(x=round(toggle_x), rely=0.5, anchor="center")
        index = self.index(selected)
        rows = [y for y in range(top, self.winfo_height(), 3)
                if self.tk.call(self._w, "identify", "tab", left + 2, y) == index]
        if rows:
            center = (rows[0] + rows[-1]) / 2
            self.motion.move_to(center, immediate=self.motion.target == 0)

    def place_marker(self, center):
        x = self.margins[0] / 2
        half_length = self.marker_height / 2
        self.marker_strip.coords(self.marker, x, center - half_length, x, center + half_length)
        self.marker_strip.itemconfigure(self.marker, state="normal")

    def destroy(self):
        if self.marker_job is not None:
            self.scheduler.after_cancel(self.marker_job)
        self.motion.cancel()
        self.hide_tip()
        super().destroy()


def configure(root):
    root.configure(background=RAIL)
    root.iconbitmap(default=str(asset_path("echopane.ico")))
    style = ttk.Style(root)
    style.theme_use("clam")
    for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont"):
        font.nametofont(name, root=root).configure(family=FONT, size=10)
    style.configure(".", background=BACKGROUND, foreground=TEXT, font=(FONT, 10))
    style.configure("Divider.TFrame", background=BORDER)
    style.configure("Panel.TFrame", background=PANEL)
    style.configure("PanelInner.TFrame", background=PANEL)
    style.configure("Panel.TLabel", background=PANEL)
    style.configure("PanelSection.TLabel", background=PANEL, font=(FONT, 10, "bold"))
    style.configure("PanelHint.TLabel", background=PANEL, foreground=MUTED, font=(FONT, 9))
    style.configure("Status.TFrame", background=STATUS_BACKGROUND)
    style.configure("Phase.TLabel", background=STATUS_BACKGROUND, font=(FONT, 10, "bold"))
    style.configure("Detail.TLabel", background=STATUS_BACKGROUND, foreground=MUTED, font=(FONT, 9))
    style.configure("Hint.TLabel", foreground=MUTED, font=(FONT, 9))
    style.configure("PageTitle.TLabel", font=(FONT, 17, "bold"))
    style.configure("MeterValue.TLabel", background=PANEL, foreground=ACCENT, font=("Bahnschrift", 11))

    style.configure("TButton", width=0, padding=(10, 5), relief="flat", borderwidth=1,
                    background=BACKGROUND, bordercolor=BORDER, lightcolor=BACKGROUND, darkcolor=BACKGROUND)
    style.map("TButton", background=[("disabled", STATUS_BACKGROUND), ("pressed", ACCENT_PALE), ("active", ACCENT_PALE)],
              foreground=[("disabled", MUTED)], bordercolor=[("focus", ACCENT)])
    style.configure("Outline.TButton", padding=(9, 4))
    style.configure("Primary.TButton", padding=(12, 6), background=STATUS_BACKGROUND, foreground=BUTTON_TEXT,
                    font=(FONT, 10, "bold"))
    style.map("Primary.TButton", background=[("disabled", STATUS_BACKGROUND), ("!disabled", STATUS_BACKGROUND)],
              foreground=[("disabled", MUTED), ("!disabled", BUTTON_TEXT)],
              bordercolor=[("focus", TEXT), ("!disabled", ACCENT)])
    style.configure("Quiet.TButton", padding=(6, 3), bordercolor=BACKGROUND, foreground=ACCENT)
    style.configure("PanelQuiet.TButton", padding=(5, 3), background=PANEL, bordercolor=PANEL, foreground=ACCENT)
    style.configure("StatusQuiet.TButton", padding=(7, 2), background=STATUS_BACKGROUND, foreground=ACCENT,
                    font=(FONT, 9))

    style.map("TCheckbutton", indicatorbackground=[("selected", ACCENT), ("!selected", FIELD)],
              indicatorforeground=[("selected", BUTTON_TEXT), ("!selected", MUTED)])

    root.theme_images = []
    configure_tabs(root, style)
    configure_fields(root, style)
    configure_history(root, style)
    rounded_layout(root, style, "Panel.TFrame", PANEL_RADIUS, (PANEL, BORDER))
    rounded_layout(root, style, "Preview.TFrame", PANEL_RADIUS, (CAPTION_BG, CAPTION_BG))
    rounded_button(root, style, "TButton", (BACKGROUND, BORDER),
                   ("disabled", STATUS_BACKGROUND, BORDER), ("pressed", ACCENT_PALE, ACCENT),
                   ("focus", BACKGROUND, ACCENT), ("active", ACCENT_PALE, BORDER))
    rounded_button(root, style, "Primary.TButton", (ACCENT, ACCENT),
                   ("disabled", METER_IDLE, METER_IDLE), ("pressed", ACCENT_PRESSED, ACCENT_PRESSED),
                   ("focus", ACCENT, TEXT), ("active", ACCENT_HOVER, ACCENT_HOVER),
                   background=STATUS_BACKGROUND)
    for name, surface in (("Quiet.TButton", BACKGROUND), ("PanelQuiet.TButton", PANEL),
                          ("StatusQuiet.TButton", STATUS_BACKGROUND)):
        rounded_button(root, style, name, (surface, surface),
                       ("disabled", surface, surface), ("pressed", ACCENT_PALE, ACCENT_BORDER),
                       ("focus", surface, ACCENT), ("active", ACCENT_PALE, ACCENT_PALE), background=surface)
    configure_dock(root, style)

    style.configure("Segment.TRadiobutton", padding=(6, 4), background=RAIL, foreground=MUTED)
    style.map("Segment.TRadiobutton", foreground=[("selected", ACCENT)])
    segment_content = [("Radiobutton.padding", {"sticky": "nswe", "children": [
        ("Radiobutton.label", {"sticky": ""}),
    ]})]
    rounded_layout(root, style, "SegmentTrack.TFrame", CONTROL_RADIUS, (RAIL, RAIL))
    rounded_layout(root, style, "Segment.TRadiobutton", 6, (RAIL, RAIL), segment_content,
                   ("selected focus", FIELD, ACCENT), ("selected", FIELD, ACCENT_BORDER),
                   ("focus", ACCENT_PALE, ACCENT), ("active", ACCENT_PALE, ACCENT_PALE), background=RAIL)


def configure_fields(root, style):
    def chevron(color):
        image = tk.PhotoImage(master=root, width=12, height=7)
        for x in range(6):
            image.put(color, to=(x, x, x + 1, x + 2))
            image.put(color, to=(11 - x, x, 12 - x, x + 2))
        root.theme_images.append(image)
        return image

    arrow = "EchoPane.Combobox.downarrow"
    style.element_create(arrow, "image", chevron(MUTED), ("disabled", chevron("#9da8b7")),
                         ("active", chevron(ACCENT)), width=28, height=18, sticky="")
    entry = style.layout("TEntry")[0][1]["children"]
    combobox = [(arrow, {"side": "right", "sticky": "ns"}), *style.layout("TCombobox")[1][1]["children"]]
    for name, content in (("TEntry", entry), ("TCombobox", combobox)):
        style.configure(name, foreground=TEXT, insertcolor=TEXT, selectbackground=ACCENT,
                        selectforeground=BUTTON_TEXT, padding=(10, 6))
        style.map(name, foreground=[("disabled", MUTED)])
        rounded_layout(root, style, name, CONTROL_RADIUS, (FIELD, BORDER), content,
                       ("disabled", STATUS_BACKGROUND, BORDER), ("focus", FIELD, ACCENT),
                       ("active", FIELD, ACCENT_BORDER), padding=2, background=PANEL)
    for option, color in (
        ("background", FIELD), ("foreground", TEXT), ("selectBackground", ACCENT),
        ("selectForeground", BUTTON_TEXT),
    ):
        root.option_add(f"*TCombobox*Listbox.{option}", color)
    root.option_add("*TCombobox*Listbox.font", (FONT, 10))


def configure_history(root, style):
    thumb, active = [rounded_image(root, 4, color, color, background=PANEL) for color in ("#bccadd", "#8da4c5")]
    root.theme_images.extend((thumb, active))
    for direction, width, height, sticky in (("Vertical", 8, 20, "ns"), ("Horizontal", 20, 8, "ew")):
        name = f"History.{direction}.TScrollbar"
        style.configure(name, troughcolor=PANEL, bordercolor=PANEL, lightcolor=PANEL, darkcolor=PANEL,
                        troughrelief="flat", borderwidth=0)
        element = f"History.{direction}.Scrollbar.thumb"
        style.element_create(element, "image", thumb, ("pressed", active), ("active", active),
                             border=4, sticky="nswe", width=width, height=height)
        style.layout(name, [(f"{direction}.Scrollbar.trough", {"sticky": sticky, "children": [
            (element, {"sticky": "nswe"}),
        ]})])


def rounded_button(root, style, name, colors, *variants, radius=CONTROL_RADIUS, background=BACKGROUND):
    # The surface paints the focus state on its border.
    content = [("Button.padding", {"sticky": "nswe", "children": [
        ("Button.label", {"sticky": "nswe"}),
    ]})]
    rounded_layout(root, style, name, radius, colors, content, *variants, padding=5, background=background)


def configure_dock(root, style):
    style.configure("Dock.TFrame", background=DOCK_TRAY)
    style.configure("DockValue.TLabel", background=DOCK_TRAY, foreground=CAPTION_EDIT, font=("Bahnschrift", 11))
    rounded_layout(root, style, "Dock.TFrame", CONTROL_RADIUS, (DOCK_TRAY, DOCK_TRAY),
                   padding=3, background=CAPTION_KEY)
    style.configure("Dock.TButton", padding=(6, 4), foreground=CAPTION_TEXT, background=DOCK_TRAY,
                    font=(FONT, 9))
    style.map("Dock.TButton", foreground=[("disabled", DOCK_MUTED), ("!disabled", CAPTION_TEXT)])
    rounded_button(root, style, "Dock.TButton", (DOCK_TRAY, DOCK_TRAY),
                   ("disabled", DOCK_TRAY, DOCK_TRAY), ("pressed", DOCK_PRESSED, DOCK_MUTED),
                   ("focus", CAPTION_HOVER, CAPTION_EDIT), ("active", CAPTION_HOVER, DOCK_RIM),
                   radius=7, background=DOCK_TRAY)


def configure_tabs(root, style):
    scale = max(1.0, float(root.tk.call("tk", "scaling")) * 0.75)
    margin = tuple(round(value * scale) for value in TAB_MARGIN)
    padding = tuple(round(value * scale) for value in TAB_PADDING)
    surface_padding = round(TAB_SURFACE_PADDING * scale)
    client = tk.PhotoImage(master=root, width=192, height=192)
    client.put(RAIL, to=(0, 0, 192, 192))
    root.theme_images.append(client)
    style.element_create("Workspace.client", "image", client, sticky="nswe", width=1, height=1)
    style.layout(TAB_STYLE, [
        ("background", {"sticky": "nswe"}), ("Workspace.client", {"sticky": "nswe"}),
    ])

    tab_content = [("Notebook.padding", {"sticky": "nswe", "children": [
        ("Notebook.label", {"sticky": "nswe"}),
    ]})]
    rounded_layout(root, style, f"{TAB_STYLE}.Tab", round(CONTROL_RADIUS * scale), (RAIL, RAIL), tab_content,
                   ("selected focus", ACCENT_PALE, ACCENT), ("selected", ACCENT_PALE, ACCENT_PALE),
                   ("active", "#e7edf4", "#e7edf4"), padding=surface_padding, background=RAIL)
    style.configure(TAB_STYLE, background=RAIL, tabposition="wn", tabplacement="nw",
                    tabmargins=margin, mintabwidth=round(112 * scale), borderwidth=0)
    style.configure(COMPACT_TAB_STYLE, mintabwidth=round(44 * scale))
    style.configure(f"{TAB_STYLE}.Tab", padding=padding, space=round(TAB_TEXT_GAP * scale), anchor="w",
                    font=(FONT, 10))
    style.configure(f"{COMPACT_TAB_STYLE}.Tab", anchor="center")
    style.map(f"{TAB_STYLE}.Tab", padding=[("selected", padding)],
              foreground=[("selected", ACCENT), ("!selected", MUTED)])
    style.configure("Rail.TButton", padding=(3, 2), background=RAIL)
    rounded_button(root, style, "Rail.TButton", (RAIL, RAIL),
                   ("pressed", ACCENT_PALE, ACCENT_BORDER), ("focus", RAIL, ACCENT),
                   ("active", "#e7edf4", "#e7edf4"), radius=8, background=RAIL)
    style.configure("RailBrand.TLabel", background=RAIL, foreground=TEXT, font=("Segoe UI", 10, "bold"))
    for name, hover, pressed in (("Caption.TButton", ACCENT_PALE, ACCENT_BORDER),
                                 ("CloseCaption.TButton", "#f8e2e5", "#f2cbd1")):
        style.configure(name, anchor="center")
        centered_icon = [("Button.label", {"sticky": ""})]
        rounded_layout(root, style, name, 7, (BACKGROUND, BACKGROUND), centered_icon,
                       ("pressed", pressed, pressed), ("focus", BACKGROUND, ACCENT),
                       ("active", hover, hover), padding=0)
    style.configure("RailTip.TLabel", background=DOCK_COLOR, foreground=BUTTON_TEXT, padding=(8, 4), font=(FONT, 9))


def rounded_layout(root, style, name, radius, colors, children=(), *variants, padding=None, background=BACKGROUND):
    image = rounded_image(root, radius, *colors, background=background)
    states = [(state, rounded_image(root, radius, fill, border, background=background))
              for state, fill, border in variants]
    root.theme_images.extend([image, *(item for _, item in states)])
    element = name + ".surface"
    minimum = 2 * radius + 3
    style.element_create(element, "image", image, *states, border=radius, sticky="nswe",
                         width=minimum, height=minimum, padding=radius if padding is None else padding)
    options = {"sticky": "nswe"}
    if children:
        options["children"] = children
    style.layout(name, [(element, options)])


def rounded_image(root, radius, fill, border, *, background):
    # Ttk tiles the center at its original size. A larger center keeps redraws cheap.
    length = 2 * radius + 192
    pixels = rounded_pixels(length, length, radius, fill, border, background=background)
    header = f"P6\n{length} {length}\n255\n".encode("ascii")
    return tk.PhotoImage(master=root, data=header + pixels[..., 2::-1].tobytes(), format="ppm")


def color_title_bar(window):
    """Apply documented DWM attributes to this window's native frame."""
    try:
        frame = ctypes.c_void_p(int(window.wm_frame(), 0))
        set_attribute = ctypes.windll.dwmapi.DwmSetWindowAttribute
    except (AttributeError, ValueError, tk.TclError):
        return
    enabled = ctypes.c_int(0)
    set_attribute(frame, 20, ctypes.byref(enabled), ctypes.sizeof(enabled))
    for attribute, color in ((34, BORDER), (35, HEADER), (36, TEXT)):
        # DWM accepts COLORREF, stored as 0x00BBGGRR.
        value = ctypes.c_uint32(int.from_bytes(bytes.fromhex(color[1:]), "little"))
        set_attribute(frame, attribute, ctypes.byref(value), ctypes.sizeof(value))


class LevelMeter(tk.Canvas):
    """Render a compact meter from normalized levels, with no capture dependency."""

    def __init__(self, parent):
        super().__init__(parent, width=110, height=9, bg=PANEL, highlightthickness=0)
        self.bars = [self.create_rectangle(0, 0, 0, 0, width=0, fill=METER_IDLE) for _ in range(30)]
        self.reading = tk.StringVar(master=self, value="—")
        self.lit = 0
        self.bind("<Configure>", self.layout_bars)

    def layout_bars(self, event):
        step = event.width / len(self.bars)
        for index, bar in enumerate(self.bars):
            left = round(index * step)
            right = max(left, round((index + 1) * step) - 2)
            self.coords(bar, left, 0, right, event.height)

    def set_level(self, level):
        level = max(0.0, min(1.0, level))
        reading = f"{level:.0%}" if level else "—"
        if self.reading.get() != reading:
            self.reading.set(reading)
        count = round(level * len(self.bars))
        if count == self.lit:
            return
        for index in range(min(count, self.lit), max(count, self.lit)):
            self.itemconfigure(self.bars[index], fill=ACCENT if index < count else METER_IDLE)
        self.lit = count

