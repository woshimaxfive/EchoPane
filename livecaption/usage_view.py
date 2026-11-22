"""Usage overview, metric trends, and local session records."""

import sqlite3
import tkinter as tk
from datetime import datetime, time, timedelta
from decimal import Decimal
from math import ceil
from tkinter import font, ttk

import theme
from views import LIVE_TITLE, PAGE_PADDING, page_title, wrap_label


PERIODS = ((1, "今天"), (7, "近 7 天"), (30, "近 30 天"))
OPEN_CAPTIONS = f"前往{LIVE_TITLE} →"
METRICS = ("估算费用", "音频 Token", "文本 Token", "会话数")
OUTCOMES = {"active": "进行中", "completed": "已结束", "interrupted": "已中断"}
COLUMNS = (("started", "开始时间", 94, "w"), ("duration", "时长", 46, "e"),
           ("audio", "音频", 52, "e"), ("text", "文本", 52, "e"),
           ("fee", "估算费用", 72, "e"), ("status", "状态", 53, "center"))


def count_label(value, *, compact=False):
    if value is None:
        return "—"
    if compact and value >= 100_000_000:
        return f"{value / 100_000_000:.1f} 亿"
    if compact and value >= 100_000:
        return f"{value / 10_000:.1f} 万"
    return f"{value:,}"


def fee_label(micros, *, compact=False, precise=False):
    if micros is None:
        return "—"
    amount = Decimal(micros).scaleb(-6)
    if precise:
        value = f"{amount:,.6f}".rstrip("0")
        whole, _, fractional = value.partition(".")
        return f"¥{whole}.{fractional.ljust(2, '0')}"
    if compact and amount >= 100_000_000:
        return f"¥{amount / 100_000_000:,.1f} 亿"
    if compact and amount >= 100_000:
        return f"¥{amount / 10_000:,.1f} 万"
    places = 2 if micros == 0 or micros >= 1_000_000 else 4 if micros >= 100 else 6
    return f"¥{amount:,.{places}f}"


def duration_label(record):
    if record.outcome == "active":
        return "—"
    minutes, seconds = divmod(record.seconds, 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours}:{minutes:02}:{seconds:02}" if hours else f"{minutes}:{seconds:02}"


def sum_metrics(rows):
    columns = ([row.estimated_micros for row in rows], [row.audio_tokens for row in rows],
               [row.text_tokens for row in rows])
    known = ([value for value in column if value is not None] for column in columns)
    totals = tuple(sum(values) if values else None for values in known)
    return totals + (len(rows),)


def summarize(rows, days, first, now):
    hourly = days == 1
    starts = [datetime.fromtimestamp(row.started_at) for row in rows]
    last_hour = max((started.hour for started in starts), default=now.hour)
    count = max(now.hour, last_hour) + 1 if hourly else days
    buckets = [[] for _ in range(count)]
    for row, started in zip(rows, starts):
        index = started.hour if hourly else (started.date() - first).days
        buckets[index].append(row)
    labels = tuple(f"{hour:02}:00" for hour in range(count)) if hourly else tuple(
        (first + timedelta(days=index)).strftime("%m-%d") for index in range(count)
    )
    return sum_metrics(rows), labels, tuple(sum_metrics(bucket) if bucket else (0, 0, 0, 0) for bucket in buckets)


class UsageTrend(tk.Canvas):
    def __init__(self, parent, scale):
        super().__init__(parent, width=1, height=round(122 * scale), bg=theme.PANEL, highlightthickness=0)
        self.scale = scale
        self.axis_font = font.Font(root=self, family=theme.FONT, size=8)
        self.tip_font = font.Font(root=self, family=theme.FONT, size=9)
        self.metric = 0
        self.labels = self.values = ()
        self.total = None
        self.plot = self.pointer = None
        self.fade = theme.Transition(self, self.shade_bars)
        self.bind("<Configure>", self.draw)
        self.bind("<Motion>", self.inspect)
        self.bind("<Leave>", self.clear_tip)

    def show(self, metric, labels, values, total, *, animate=False):
        if (metric, labels, values, total) == (self.metric, self.labels, self.values, self.total):
            return
        self.metric, self.labels, self.values, self.total = metric, labels, values, total
        self.draw()
        if animate and self.fade.enabled:
            self.fade.move_to(0, immediate=True)
            self.fade.move_to(1)

    def draw(self, _event=None):
        self.delete("all")
        self.plot = None
        width, height = self.winfo_width(), self.winfo_height()
        if self.total is None:
            self.create_text(width / 2, height / 2, text="服务暂未返回该指标的用量",
                             fill=theme.MUTED, font=self.tip_font)
            return
        peak = max(value for value in self.values if value is not None)
        step = max(1, (peak + 1) // 2)
        magnitude = 10 ** (len(str(step)) - 1)
        step = ((step + magnitude - 1) // magnitude) * magnitude
        ticks = (0, 1) if peak <= 1 else (0, step, step * 2)
        labels = [self.value_label(value) for value in ticks]
        scale = self.scale
        text_height = self.axis_font.metrics("linespace")
        left = max(self.axis_font.measure(label) for label in labels) + round(12 * scale)
        right = width - round(4 * scale)
        top, bottom = (text_height + 1) // 2 + 2, height - text_height - round(7 * scale)
        if right <= left or bottom <= top:
            return
        slot = (right - left) / len(self.values)
        self.plot = (left, top, right, bottom, slot)
        self.highlight = self.create_rectangle(0, 0, 0, 0, fill=theme.FIELD, width=0, state="hidden")
        for value, label in zip(ticks, labels):
            y = bottom - (bottom - top) * value / ticks[-1]
            self.create_line(left, y, right, y, fill=theme.BORDER)
            self.create_text(left - round(8 * scale), y, text=label, anchor="e", fill=theme.MUTED, font=self.axis_font)

        label_width = max(self.axis_font.measure(label) for label in self.labels)
        every = max(1, ceil((label_width + 12 * scale) / slot))
        for index, value in enumerate(self.values):
            x = left + (index + 0.5) * slot
            if value:
                half = min(15 * scale, slot * 0.29)
                y = bottom - max(1, (bottom - top) * value / ticks[-1])
                self.draw_bar(x - half, y, x + half, bottom)
            if index % every == 0:
                x = min(x, width - label_width / 2 - 1)
                self.create_text(x, bottom + round(6 * scale), text=self.labels[index], anchor="n",
                                 fill=theme.MUTED, font=self.axis_font)

        if self.fade.job is not None:
            self.shade_bars(self.fade.value)
        self.draw_tip()

    def draw_bar(self, left, top, right, bottom):
        radius = min(round(3 * self.scale), (right - left) / 2, (bottom - top) / 2)
        self.create_polygon(
            left, bottom, left, bottom, left, top + radius, left, top + radius,
            left, top, left + radius, top, left + radius, top,
            right - radius, top, right - radius, top, right, top,
            right, top + radius, right, top + radius, right, bottom, right, bottom,
            smooth=True, outline="", fill=theme.ACCENT, tags="bar",
        )

    def value_label(self, value, *, precise=False):
        if self.metric == 0:
            return fee_label(value, compact=not precise, precise=precise)
        field = count_label(value, compact=not precise)
        if precise and value is not None:
            field += " 场" if self.metric == 3 else " Token"
        return field

    def shade_bars(self, progress):
        base = bytes.fromhex(theme.ACCENT_PALE[1:])
        color = bytes.fromhex(theme.ACCENT[1:])
        mixed = bytes(round(a + (b - a) * progress) for a, b in zip(base, color))
        self.itemconfigure("bar", fill=f"#{mixed.hex()}")

    def inspect(self, event):
        self.pointer = (event.x, event.y)
        self.draw_tip()

    def clear_tip(self, _event=None):
        self.pointer = None
        self.draw_tip()

    def draw_tip(self):
        self.delete("tip")
        if not self.plot:
            return
        self.itemconfigure(self.highlight, state="hidden")
        if self.pointer is None:
            return
        x, y = self.pointer
        left, top, right, bottom, slot = self.plot
        if not (left <= x < right and top <= y <= bottom):
            return
        index = min(int((x - left) / slot), len(self.values) - 1)
        edge = left + index * slot
        self.coords(self.highlight, edge, top, edge + slot, bottom)
        self.itemconfigure(self.highlight, state="normal")

        label = self.labels[index]
        value = self.value_label(self.values[index], precise=True)
        inset = round(8 * self.scale)
        width = max(self.tip_font.measure(label), self.tip_font.measure(value)) + 2 * inset
        height = self.tip_font.metrics("linespace") * 2 + 2 * inset
        tip_x = edge + slot + inset
        if tip_x + width > self.winfo_width():
            tip_x = max(0, edge - width - inset)
        tip_y = max(0, min(y - height / 2, self.winfo_height() - height))
        self.create_rectangle(tip_x, tip_y, tip_x + width, tip_y + height,
                              fill=theme.DOCK_COLOR, width=0, tags="tip")
        self.create_text(tip_x + inset, tip_y + inset, text=f"{label}\n{value}", anchor="nw",
                         font=self.tip_font, fill=theme.BUTTON_TEXT, tags="tip")

    def destroy(self):
        self.fade.cancel()
        super().destroy()


class UsageMetrics(ttk.Frame):
    def __init__(self, parent, scale, select):
        super().__init__(parent, style="PanelInner.TFrame")
        self.scale = scale
        self.metric = tk.IntVar(self, value=0)
        self.values = tuple(tk.StringVar(self, "—") for _ in METRICS)
        self.cells = []
        self.controls = []
        self.marker_box = self.target_box = None
        self.marker = tk.Frame(self, bg=theme.ACCENT, height=max(2, round(2 * scale)), takefocus=0)
        self.motion = theme.Transition(self, self.place_marker)
        self.columns = 0
        for index, title in enumerate(METRICS):
            cell = ttk.Frame(self, style="PanelInner.TFrame", padding=(round(8 * scale), 0, round(8 * scale), 6))
            label = ttk.Label(cell, text=title, style="PanelHint.TLabel", cursor="hand2")
            label.pack(anchor="w", padx=3)
            button = ttk.Radiobutton(cell, variable=self.metric, value=index, textvariable=self.values[index],
                                     style="UsageMetric.TRadiobutton", cursor="hand2", command=select)
            button.pack(fill="x")
            for widget in (cell, label):
                widget.bind("<ButtonRelease-1>", lambda _event, control=button: control.invoke())
            cell.bind("<Configure>", self.resize_marker)
            self.cells.append(cell)
            self.controls.append(button)
        self.bind("<Configure>", self.layout_cells)
        self.layout_cells()

    def layout_cells(self, event=None):
        columns = 2 if event and event.width < round(340 * self.scale) else 4
        if self.columns == columns:
            return
        self.columns = columns
        for index in range(len(METRICS)):
            visible = index < columns
            self.columnconfigure(index, weight=int(visible), uniform="metric" if visible else "")
        for index, cell in enumerate(self.cells):
            row, column = divmod(index, columns)
            cell.grid(row=row, column=column, sticky="ew", pady=(0 if row == 0 else 8, 0))

    def resize_marker(self, event):
        if event.widget is self.cells[self.metric.get()]:
            self.select()

    def select(self, *, animate=False):
        cell = self.cells[self.metric.get()]
        if cell.winfo_width() <= 1:
            return
        inset = round(8 * self.scale)
        box = (cell.winfo_x() + inset, cell.winfo_y() + cell.winfo_height() - self.marker.winfo_reqheight(),
               max(1, cell.winfo_width() - 2 * inset))
        if box == self.target_box:
            return
        self.start_box, self.target_box = self.marker_box or box, box
        slide = animate and self.start_box[1] == box[1] and self.motion.enabled
        if slide:
            self.motion.move_to(0, immediate=True)
        self.motion.move_to(1, immediate=not slide)

    def place_marker(self, progress):
        self.marker_box = tuple(round(a + (b - a) * progress) for a, b in zip(self.start_box, self.target_box))
        x, y, width = self.marker_box
        self.marker.place(x=x, y=y, width=width)
        self.marker.lift()

    def destroy(self):
        self.motion.cancel()
        super().destroy()


class UsageDetails(ttk.Frame):
    """Present the recorded values with readable columns and bounded table height."""

    def __init__(self, parent, scale, can_recall, open_history):
        super().__init__(parent, style="Panel.TFrame", padding=round(12 * scale))
        self.scale = scale
        self.can_recall, self.open_history = can_recall, open_history
        self.columnconfigure(0, weight=1)
        self.table_font = font.Font(root=self, family=theme.FONT, size=9)
        self.rows = {}
        self.widths = [round(column[2] * scale) for column in COLUMNS]

        header = ttk.Frame(self, style="Panel.TFrame")
        header.grid(row=0, columnspan=2, sticky="ew", pady=(1, 6))
        ttk.Label(header, text="会话记录", style="PanelSection.TLabel").pack(side="left")
        self.recall = ttk.Button(header, text="回看这场", style="PanelQuiet.TButton", command=self.open_selected)
        self.recall.state(["disabled"])
        self.recall.pack(side="right")
        self.table = ttk.Treeview(self, columns=tuple(column[0] for column in COLUMNS), show="headings",
                                  height=1, style="Usage.Treeview", selectmode="browse")
        self.table.grid(row=1, column=0, sticky="ew")
        self.scrollbar = ttk.Scrollbar(self, orient="vertical", command=self.table.yview,
                                       style="History.Vertical.TScrollbar")
        self.scrollbar.grid(row=1, column=1, sticky="ns", padx=(3, 0))
        self.scrollbar.grid_remove()
        self.horizontal = ttk.Scrollbar(self, orient="horizontal", command=self.table.xview,
                                        style="History.Horizontal.TScrollbar")
        self.horizontal.grid(row=2, column=0, sticky="ew", pady=(4, 0))
        self.horizontal.grid_remove()
        self.notice = ttk.Label(self, style="PanelHint.TLabel", anchor="w")
        self.notice.grid(row=3, columnspan=2, sticky="ew", pady=(8, 0))
        wrap_label(self.notice)
        self.table.tag_configure("alternate", background=theme.FIELD)
        self.table.tag_configure("active", foreground=theme.ACCENT)
        for name, title, _, anchor in COLUMNS:
            self.table.heading(name, text=title, anchor=anchor)
            self.table.column(name, minwidth=1, stretch=False, anchor=anchor)
        self.table.configure(yscrollcommand=lambda first, last: self.scroll_changed(self.scrollbar, first, last),
                             xscrollcommand=lambda first, last: self.scroll_changed(self.horizontal, first, last))
        self.table.bind("<Configure>", self.size_columns)
        self.table.bind("<<TreeviewSelect>>", self.update_recall)

    def update_recall(self, _event=None):
        selected = self.table.selection()
        available = len(selected) == 1 and self.can_recall(selected[0])
        self.recall.state(["!disabled"] if available else ["disabled"])

    def open_selected(self):
        selected = self.table.selection()
        if selected:
            self.open_history(selected[0])

    def scroll_changed(self, bar, first, last):
        bar.set(first, last)
        if float(first) == 0 and float(last) >= 1:
            bar.grid_remove()
        elif not bar.winfo_manager():
            bar.grid()

    def size_columns(self, _event=None):
        width = self.table.winfo_width()
        extra, remainder = divmod(max(0, width - sum(self.widths)), len(COLUMNS))
        for index, ((name, _, _, _), minimum) in enumerate(zip(COLUMNS, self.widths)):
            self.table.column(name, width=minimum + extra + int(index < remainder))

    def show(self, records, notice):
        values_by_id = {}
        widest = [column[1] for column in COLUMNS]
        for index, row in enumerate(records):
            started = datetime.fromtimestamp(row.started_at).strftime("%m-%d %H:%M")
            values = (started, duration_label(row), count_label(row.audio_tokens), count_label(row.text_tokens),
                      fee_label(row.estimated_micros), OUTCOMES[row.outcome])
            tags = ("alternate",) if index % 2 else ()
            if row.outcome == "active":
                tags += ("active",)
            values_by_id[row.ident] = (values, tags)
            if row.ident not in self.rows:
                self.table.insert("", "end", iid=row.ident, values=values, tags=tags)
            elif values_by_id[row.ident] != self.rows[row.ident]:
                self.table.item(row.ident, values=values, tags=tags)
            widest = [max(field, previous, key=len) for field, previous in zip(values, widest)]

        removed = self.rows.keys() - values_by_id.keys()
        if removed:
            self.table.delete(*removed)
        if tuple(values_by_id) != tuple(self.rows):
            self.table.set_children("", *values_by_id)
        self.rows = values_by_id
        self.widths = [max(round(column[2] * self.scale), self.table_font.measure(value) + round(12 * self.scale))
                       for column, value in zip(COLUMNS, widest)]
        self.size_columns()
        self.table.configure(height=max(1, min(20, len(records))))
        self.notice.configure(text=notice)
        self.update_recall()


class UsagePage(ttk.Frame):
    def __init__(self, parent, history, current_usage, scale, *, open_live, can_recall, open_history):
        super().__init__(parent, padding=PAGE_PADDING)
        self.history, self.current_usage = history, current_usage
        self.open_live = open_live
        self.scale = scale
        self.display_date = self.display_hour = self.clock_job = None
        self.columnconfigure(0, weight=1)
        self.rowconfigure(1, weight=1)
        page_title(self, "用量统计")
        self.period = ttk.Combobox(self, width=8, state="readonly", values=tuple(title for _, title in PERIODS))
        self.period.current(0)
        self.period.grid(row=0, column=1, sticky="e")
        self.period.bind("<<ComboboxSelected>>", self.change_period)

        self.configure_usage_styles()
        self.viewport = tk.Canvas(self, background=theme.BACKGROUND, bd=0, highlightthickness=0, takefocus=0,
                                  width=1, height=1, yscrollincrement=round(17 * scale))
        self.viewport.grid(row=1, columnspan=2, sticky="nsew", pady=(8, 0))
        self.scrollbar = ttk.Scrollbar(self, command=self.viewport.yview, style="History.Vertical.TScrollbar")
        self.viewport.configure(yscrollcommand=self.scroll_changed)
        content = ttk.Frame(self.viewport)
        content.columnconfigure(0, weight=1)
        self.content = content
        self.content_window = self.viewport.create_window(0, 0, window=content, anchor="nw")
        self.viewport.bind("<Configure>", self.resize_content)
        content.bind("<Configure>", self.update_scrollregion)

        self.overview = ttk.Frame(content, padding=(round(13 * scale), round(11 * scale)),
                                  style="Panel.TFrame")
        self.overview.grid(row=0, sticky="ew")
        self.overview.columnconfigure(0, weight=1)
        self.metrics = UsageMetrics(self.overview, scale, self.change_metric)
        self.metrics.grid(row=0, columnspan=2, sticky="ew")
        ttk.Frame(self.overview, height=1, style="Divider.TFrame").grid(row=1, columnspan=2, sticky="ew")
        self.chart_title = ttk.Label(self.overview, style="PanelSection.TLabel")
        self.chart_title.grid(row=2, column=0, sticky="w", pady=(10, 7))
        self.chart_interval = ttk.Label(self.overview, style="PanelHint.TLabel")
        self.chart_interval.grid(row=2, column=1, sticky="e", pady=(10, 7))
        self.trend = UsageTrend(self.overview, scale)
        self.trend.grid(row=3, columnspan=2, sticky="ew")

        self.details = UsageDetails(content, scale, can_recall, open_history)
        self.details.grid(row=1, sticky="ew", pady=(11, 0))
        self.empty = ttk.Frame(content, style="Panel.TFrame", padding=(round(16 * scale), round(17 * scale)))
        self.empty.columnconfigure(1, weight=1)
        self.empty.grid(row=0, sticky="ew")
        icon = theme.glyph(self, "usage", theme.ACCENT)
        icon_tile = ttk.Frame(self.empty, style="UsageIcon.TFrame", padding=round(7 * scale))
        icon_tile.grid(row=0, column=0, sticky="n", padx=(0, 12), rowspan=2)
        icon_label = ttk.Label(icon_tile, image=icon, style="UsageIcon.TLabel")
        icon_label.image = icon
        icon_label.pack()
        self.empty_title = ttk.Label(self.empty, text="暂无用量记录", style="UsageEmpty.TLabel")
        self.empty_title.grid(row=0, column=1, sticky="ew")
        self.empty_hint = ttk.Label(self.empty, style="PanelHint.TLabel")
        self.empty_hint.grid(row=1, column=1, sticky="ew", pady=(4, 0))
        wrap_label(self.empty_hint)
        self.empty_action = ttk.Button(self.empty, text=OPEN_CAPTIONS, style="PanelQuiet.TButton", command=open_live)
        self.empty_action.grid(row=2, column=1, sticky="w", pady=(8, 0))

        self.overview.grid_remove()
        self.details.grid_remove()
        self.bind("<Map>", self.on_map)
        self.bind("<Unmap>", self.on_unmap)
        self.viewport.bind("<MouseWheel>", self.scroll_content)
        self.bind_content_wheel(content)
        for control in (*self.metrics.controls, self.details.table, self.details.recall, self.empty_action):
            control.bind("<FocusIn>", self.reveal_focus, add="+")

    def configure_usage_styles(self):
        root = self.winfo_toplevel()
        style = ttk.Style(self)
        style.configure("UsageMetric.TRadiobutton", background=theme.PANEL, foreground=theme.TEXT,
                        font=("Bahnschrift", 16), padding=(2, 1))
        style.map("UsageMetric.TRadiobutton", foreground=[("selected", theme.ACCENT), ("active", theme.ACCENT)])
        radio_content = [("Radiobutton.padding", {"sticky": "nswe", "children": [
            ("Radiobutton.label", {"sticky": "w"}),
        ]})]
        theme.rounded_layout(root, style, "UsageMetric.TRadiobutton", 5, (theme.PANEL, theme.PANEL), radio_content,
                             ("focus", theme.ACCENT_PALE, theme.ACCENT_BORDER), ("active", theme.FIELD, theme.FIELD),
                             padding=2, background=theme.PANEL)
        style.configure("UsageEmpty.TLabel", background=theme.PANEL, font=(theme.FONT, 11, "bold"))
        style.configure("UsageIcon.TLabel", background=theme.ACCENT_PALE)
        theme.rounded_layout(root, style, "UsageIcon.TFrame", round(7 * self.scale),
                             (theme.ACCENT_PALE, theme.ACCENT_PALE), background=theme.PANEL)
        style.layout("Usage.Treeview", [("Treeview.treearea", {"sticky": "nswe"})])
        style.configure("Usage.Treeview", background=theme.PANEL, fieldbackground=theme.PANEL,
                        foreground=theme.TEXT, borderwidth=0, rowheight=round(27 * self.scale), font=(theme.FONT, 9))
        style.configure("Usage.Treeview.Heading", background=theme.STATUS_BACKGROUND, foreground=theme.MUTED,
                        font=(theme.FONT, 9), padding=(4, 5), relief="flat", borderwidth=0)
        style.map("Usage.Treeview", background=[("selected", theme.ACCENT_PALE)],
                  foreground=[("selected", theme.TEXT)])
        style.map("Usage.Treeview.Heading", background=[("active", theme.STATUS_BACKGROUND)])

    def resize_content(self, event):
        self.viewport.itemconfigure(self.content_window, width=event.width)

    def update_scrollregion(self, event):
        self.viewport.configure(scrollregion=(0, 0, event.width, event.height))

    def scroll_changed(self, first, last):
        self.scrollbar.set(first, last)
        if float(first) == 0 and float(last) >= 1:
            self.scrollbar.place_forget()
        elif not self.scrollbar.winfo_manager():
            self.scrollbar.place(in_=self.viewport, relx=1, x=12, relheight=1, anchor="ne")

    def bind_content_wheel(self, widget):
        widget.bind("<MouseWheel>", self.scroll_content, add="+")
        for child in widget.winfo_children():
            self.bind_content_wheel(child)

    def scroll_content(self, event):
        steps = max(1, abs(event.delta) // 120) * (-1 if event.delta > 0 else 1)
        table = self.details.table
        if event.widget is table:
            first, last = table.yview()
            if (steps < 0 and first > 0) or (steps > 0 and last < 1):
                table.yview_scroll(steps, "units")
                return "break"
        self.viewport.yview_scroll(steps, "units")
        return "break"

    def reveal_focus(self, event):
        widget = event.widget
        top = widget.winfo_rooty() - self.viewport.winfo_rooty()
        overflow = top + widget.winfo_height() - self.viewport.winfo_height()
        delta = top if top < 0 else max(0, min(top, overflow))
        if delta:
            first = self.viewport.yview()[0]
            height = max(1, self.content.winfo_height())
            self.viewport.yview_moveto(first + delta / height)

    def change_period(self, _event):
        self.viewport.yview_moveto(0)
        self.details.table.yview_moveto(0)
        self.refresh()

    def on_map(self, _event):
        self.refresh()
        self.clock_job = self.after(30_000, self.update_clock)

    def on_unmap(self, _event):
        if self.clock_job is not None:
            self.after_cancel(self.clock_job)
            self.clock_job = None

    def update_clock(self):
        now = datetime.now()
        if self.display_date != now.date():
            self.refresh(now)
        elif self.days == 1 and self.display_hour != now.hour:
            self.update_current(now)
        self.clock_job = self.after(30_000, self.update_clock)

    def refresh(self, now=None):
        now = now or datetime.now()
        self.days = PERIODS[self.period.current()][0]
        self.display_date = now.date()
        self.first = now.date() - timedelta(days=self.days - 1)
        self.start = datetime.combine(self.first, time.min).timestamp()
        self.end = datetime.combine(now.date() + timedelta(days=1), time.min).timestamp()
        try:
            self.saved = self.history.between(self.start, self.end)
        except (OSError, sqlite3.Error):
            self.saved = []
            self.read_failed = True
        else:
            self.read_failed = False
        self.update_current(now)

    def update_current(self, now=None):
        now = now or datetime.now()
        if now.date() != self.display_date:
            self.refresh(now)
            return
        self.display_hour = now.hour
        rows = self.saved
        current = self.current_usage()
        if current and self.start <= current.started_at < self.end and all(row.ident != current.ident for row in rows):
            rows = [current, *rows]
        error = "暂时无法读取本机历史用量。"
        if not rows:
            self.viewport.yview_moveto(0)
            self.overview.grid_remove()
            self.details.grid_remove()
            self.empty.grid()
            self.empty_title.configure(text="无法读取用量" if self.read_failed else "此时段暂无用量")
            self.empty_hint.configure(text="" if self.read_failed else "开启字幕后，这里会显示用量。")
            self.empty_action.configure(text="重试" if self.read_failed else OPEN_CAPTIONS,
                                        command=self.refresh if self.read_failed else self.open_live)
            return
        self.empty.grid_remove()
        self.overview.grid()
        self.details.grid()
        self.totals, self.labels, self.buckets = summarize(rows, self.days, self.first, now)
        for index, (label, value) in enumerate(zip(self.metrics.values, self.totals)):
            formatted = fee_label(value, compact=True) if index == 0 else count_label(value, compact=True)
            if label.get() != formatted:
                label.set(formatted)
        self.chart_interval.configure(text="按开始小时" if self.days == 1 else "按开始日期")
        self.details.show(rows, error if self.read_failed else "费用按百炼北京地域公开单价估算")
        self.show_metric()

    def change_metric(self):
        self.show_metric(animate=True)

    def show_metric(self, *, animate=False):
        metric = self.metrics.metric.get()
        self.metrics.select(animate=animate)
        self.chart_title.configure(text=f"{METRICS[metric]}趋势")
        self.trend.show(metric, self.labels, tuple(bucket[metric] for bucket in self.buckets),
                        self.totals[metric], animate=animate)
