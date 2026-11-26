"""Adaptive, movable subtitles with controls on the hovered surface."""

import ctypes
import time
import tkinter as tk
from ctypes import wintypes
from tkinter import font

import theme
from caption_controls import CaptionControls
from native_windows import (
    GWL_EXSTYLE, GW_OWNER, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER, USER32,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, LayeredBitmap, monitor_work_area,
    set_mouse_passthrough, set_window_owner, window_work_area,
)
from surfaces import rounded_pixels


POLL_MS = 40
HIDE_DELAY = 0.15
SHRINK_DELAY_MS = 900


class CaptionOverlay(tk.Toplevel):
    def __init__(self, root, appearance, dismiss, stop, change_size, save_position,
                 *, change_background, change_lock):
        super().__init__(root, bg=theme.CAPTION_KEY)
        self.withdraw()
        self.capture_visibility = None
        self.title("字幕浮窗")
        self.overrideredirect(True)
        self.attributes("-topmost", True)
        self.attributes("-transparentcolor", theme.CAPTION_KEY)
        self.protocol("WM_DELETE_WINDOW", dismiss)
        self.scale = max(1.0, float(root.tk.call("tk", "scaling")) * 0.75)
        self.padding = round(16 * self.scale)
        self.gap = round(6 * self.scale)
        self.position = appearance.position
        self.save_position = save_position
        self.change_lock = change_lock
        self.background = appearance.background
        self.locked = appearance.locked
        self.hovered = False
        self.last_inside = 0.0
        self.timer = None
        self.render_job = None
        self.shrink_job = None
        self.shrink_ready = False
        self.drag_origin = None
        self.window_bounds = None
        self.content_height = 0
        self.watch_area = None
        self.lines = {}
        self.original = None
        self.status_message = "字幕预览"
        self.interruption = ""

        self.surface = tk.Canvas(self, bg=theme.CAPTION_KEY, bd=0, highlightthickness=0)
        self.surface.pack(fill="both", expand=True)
        self.backdrop = tk.Toplevel(self, bg=theme.DOCK_COLOR)
        self.backdrop.withdraw()
        self.backdrop.overrideredirect(True)
        self.backdrop.attributes("-topmost", True)
        self.backdrop_bitmap = LayeredBitmap()
        self.backdrop_surface = tk.Canvas(self.backdrop, bg=theme.DOCK_COLOR, bd=0, highlightthickness=0)
        self.backdrop_surface.pack(fill="both", expand=True)
        self.shades = [self.make_panel(self.surface, theme.CAPTION_BG) for _ in range(2)]
        size = appearance.caption_size
        self.caption_font = font.Font(root=self, family=theme.FONT, size=size)
        self.previous_font = font.Font(root=self, family=theme.FONT, size=theme.secondary_caption_size(size))
        stroke = max(1, round(self.scale))
        self.stroke_offsets = [(stroke, 2 * stroke), (-stroke, 0), (stroke, 0), (0, -stroke), (0, stroke), (0, 0)]
        self.previous_items = self.make_text("previous", theme.CAPTION_PREVIOUS, self.previous_font)
        self.current_items = self.make_text("latest", theme.CAPTION_TEXT, self.caption_font)
        self.layout_items = {
            "previous": self.surface.create_text(-1, 0, anchor="ne", font=self.previous_font, fill=theme.CAPTION_KEY),
            "current": self.surface.create_text(-1, 0, anchor="ne", font=self.caption_font, fill=theme.CAPTION_KEY),
        }
        self.controls = CaptionControls(
            self.surface, change_size,
            lambda: change_background("shade" if self.background == "transparent" else "transparent"),
            lambda: self.set_locked(not self.locked), stop, dismiss,
        )
        self.control_item = self.surface.create_window(0, 0, window=self.controls, anchor="n", state="hidden")
        self.motion = theme.Transition(root, self.draw_dock)
        self.drag_surfaces = (self.surface, self.backdrop_surface, *self.controls.drag_surfaces)
        self.sync_controls()
        for widget in self.drag_surfaces:
            widget.bind("<ButtonPress-1>", self.begin_drag)
            widget.bind("<B1-Motion>", self.drag)
            widget.bind("<ButtonRelease-1>", self.finish_drag)

        self.bind("<Map>", self.watch_mapping)
        self.bind("<Unmap>", self.watch_mapping)

    @property
    def frame(self):
        return int(self.wm_frame(), 0)

    @property
    def backdrop_frame(self):
        return int(self.backdrop.wm_frame(), 0)

    @staticmethod
    def make_panel(surface, color):
        return surface.create_polygon(0, 0, 0, 0, 0, 0, fill=color,
                                      smooth=True, splinesteps=12, state="hidden")

    def make_text(self, tag, color, text_font):
        return [
            self.surface.create_text(0, 0, fill=color if offset == (0, 0) else theme.CAPTION_STROKE,
                                     text="", font=text_font, anchor="s", justify="center",
                                     tags=(tag,))
            for offset in self.stroke_offsets
        ]

    @staticmethod
    def set_panel_bounds(surface, item, bounds, radius):
        left, top, right, bottom = bounds
        radius = min(radius, (right - left) // 2, (bottom - top) // 2)
        surface.coords(item, left, top + radius, left, top, left + radius, top,
                       right - radius, top, right, top, right, top + radius,
                       right, bottom - radius, right, bottom, right - radius, bottom,
                       left + radius, bottom, left, bottom, left, bottom - radius)

    def position_controls(self, progress):
        if self.window_bounds is not None:
            _, _, width, height = self.window_bounds
            offset = round((1 - progress) * 4 * self.scale)
            self.surface.coords(self.control_item, width // 2, height - self.content_height + self.gap - offset)

    def draw_dock(self, progress):
        self.position_controls(progress)
        if progress == 0 and not self.hovered:
            self.surface.itemconfigure(self.control_item, state="hidden")
            self.backdrop.withdraw()
        elif self.backdrop.state() != "withdrawn":
            self.paint_backdrop(progress)

    def paint_backdrop(self, progress):
        left, top, width, height = self.window_bounds
        bitmap = self.backdrop_bitmap
        try:
            if bitmap.size != (width, height):
                pixels = rounded_pixels(width, height, round(theme.DOCK_RADIUS * self.scale),
                                        theme.DOCK_COLOR, theme.DOCK_RIM)
                bitmap.replace(pixels)
            bitmap.present(self.backdrop_frame, left, top, theme.DOCK_OPACITY * max(0.05, progress))
        except OSError:
            self.backdrop.withdraw()
            return False
        return True

    def sync_controls(self):
        self.controls.sync(self.caption_font.cget("size"), self.background, self.locked)
        cursor = "arrow" if self.locked else "fleur"
        for widget in self.drag_surfaces:
            widget.configure(cursor=cursor)

    def set_hovered(self, hovered, *, immediate=False):
        if hovered == self.hovered and not immediate:
            return
        self.hovered = hovered
        set_mouse_passthrough(self.frame, not hovered)
        if hovered:
            self.surface.itemconfigure(self.control_item, state="normal")
            if self.backdrop.state() == "withdrawn":
                _, _, width, height = self.window_bounds
                self.backdrop.geometry(f"{width}x{height}")
                frame = self.backdrop_frame
                style = USER32.GetWindowLongW(frame, GWL_EXSTYLE)
                USER32.SetWindowLongW(frame, GWL_EXSTYLE, style | WS_EX_LAYERED | WS_EX_NOACTIVATE)
                # Windows always keeps an owned window above its owner.
                set_window_owner(self.frame, frame)
                if self.paint_backdrop(self.motion.value):
                    self.backdrop.deiconify()
                    self.backdrop.update_idletasks()
        if self.backdrop.winfo_ismapped():
            set_mouse_passthrough(self.backdrop_frame, not hovered)
        self.draw_shades()
        self.motion.move_to(float(hovered), immediate=immediate)

    def caption_area(self):
        if self.watch_area is None or self.window_bounds is None:
            return None
        left, top, _, _ = self.window_bounds
        x0, y0, x1, y1 = self.watch_area
        return left + x0, top + y0, x1 - x0, y1 - y0

    def pointer_at(self, x, y, now):
        target = self.window_bounds if self.hovered else self.caption_area()
        if target is not None:
            left, top, width, height = target
            margin = 0 if self.hovered else self.gap
            if self.drag_origin or (left - margin <= x < left + width + margin
                                    and top - margin <= y < top + height + margin):
                self.last_inside = now
                self.set_hovered(True)
                return
        if self.hovered and now - self.last_inside >= HIDE_DELAY:
            self.set_hovered(False)

    def poll(self):
        self.timer = None
        if not self.winfo_ismapped():
            return
        point = wintypes.POINT()
        if USER32.GetCursorPos(ctypes.byref(point)):
            self.pointer_at(point.x, point.y, time.monotonic())
        self.resume_poll()

    def resume_poll(self):
        if self.timer is None and self.winfo_ismapped():
            self.timer = self.master.after(POLL_MS, self.poll)

    def pause_poll(self):
        if self.timer is not None:
            self.master.after_cancel(self.timer)
            self.timer = None
        self.finish_drag()
        self.set_hovered(False, immediate=True)

    def watch_mapping(self, event):
        if event.widget is not self:
            return
        if self.winfo_ismapped():
            style = USER32.GetWindowLongW(self.frame, GWL_EXSTYLE)
            USER32.SetWindowLongW(self.frame, GWL_EXSTYLE, style | WS_EX_NOACTIVATE)
            set_mouse_passthrough(self.frame, not self.hovered)
            self.resume_poll()
        else:
            self.pause_poll()

    def place_frame(self, bounds):
        previous = self.window_bounds
        self.window_bounds = bounds
        if self.winfo_ismapped():
            # Signed screen coordinates allow dragging onto monitors left of the main one.
            USER32.SetWindowPos(self.frame, None, *bounds, SWP_NOZORDER | SWP_NOACTIVATE)
            if self.backdrop.winfo_ismapped():
                if previous is not None and bounds[2:] == previous[2:]:
                    left, top, _, _ = bounds
                    USER32.SetWindowPos(self.backdrop_frame, None, left, top, 0, 0,
                                        SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)
                else:
                    self.paint_backdrop(self.motion.value)

    def reveal(self):
        if self.capture_visibility is not None:
            self.capture_visibility = True
            return
        if self.state() == "withdrawn":
            self.position = self.placement()[1]
            self.schedule_watch()
            self.update_idletasks()
            _, _, width, height = self.window_bounds
            self.geometry(f"{width}x{height}")
            self.attributes("-alpha", 0.0)
            self.deiconify()
            self.update_idletasks()
            self.place_frame(self.window_bounds)
            self.attributes("-alpha", 1.0)
        self.resume_poll()

    def hide(self, *, remember=True):
        if self.capture_visibility is not None:
            self.capture_visibility = False
            return
        if remember:
            self.remember_position()
        self.pause_poll()
        self.withdraw()

    def suspend_for_capture(self):
        was_visible = self.state() != "withdrawn"
        self.hide(remember=False)
        self.capture_visibility = was_visible

    def resume_after_capture(self):
        visible = self.capture_visibility
        self.capture_visibility = None
        if visible:
            self.reveal()

    def move_to(self, position):
        self.position = position
        self.schedule_watch()

    def remember_position(self):
        if self.state() != "withdrawn" or self.capture_visibility:
            self.finish_drag()
            self.position = self.placement()[1]
            self.save_position(self.position)

    def begin_drag(self, event):
        if self.hovered and not self.locked:
            self.drag_origin = (event.x_root, event.y_root, self.window_bounds)

    def drag(self, event):
        if self.drag_origin is not None:
            x, y, (left, top, width, height) = self.drag_origin
            self.place_frame((left + event.x_root - x, top + event.y_root - y, width, height))

    def finish_drag(self, _event=None):
        if self.drag_origin is None:
            return
        _, _, old = self.drag_origin
        self.drag_origin = None
        if self.window_bounds != old:
            left, top, width, height = self.window_bounds
            self.position = (left + width // 2, top + height)
            self.save_position(self.position)
        self.last_inside = time.monotonic()
        self.schedule_watch()

    def set_background(self, background):
        self.background = background
        self.sync_controls()
        self.draw_shades()

    def set_locked(self, locked):
        if locked != self.locked:
            self.finish_drag()
            self.locked = locked
            self.sync_controls()
            self.change_lock(locked)

    def set_size(self, size):
        self.caption_font.configure(size=size)
        self.previous_font.configure(size=theme.secondary_caption_size(size))
        self.sync_controls()
        self.shrink_ready = True
        self.schedule_watch()

    def set_active(self, active):
        self.controls.set_active(active)
        self.schedule_watch()

    def set_stopping(self):
        self.controls.stop_button.state(["disabled"])

    def begin(self):
        self.lines.clear()
        self.reset("等待字幕…")
        self.reveal()

    def reset(self, message, *, original=None):
        self.status_message = message
        self.original = original
        self.interruption = ""
        self.shrink_ready = True
        self.schedule_watch()

    def show_interruption(self, label):
        self.interruption = label
        self.schedule_watch()
        self.reveal()

    def update_caption(self, ident, text):
        lines = self.lines | {ident: text}
        if len(lines) > 2:
            del lines[next(iter(lines))]
        self.set_captions(lines)

    def set_captions(self, lines, *, original=None):
        if lines != self.lines or original != self.original:
            self.lines = lines
            self.original = original
            self.schedule_watch()

    def schedule_watch(self):
        if self.render_job is None:
            self.render_job = self.master.after_idle(self.draw_watch)

    def placement(self):
        if self.position is not None:
            x, y = self.position
            work = monitor_work_area((x, y - 1, 1, 1), nearest=False)
            if work is not None:
                return work, self.position
        work = window_work_area(int(self.master.wm_frame(), 0))
        if work is None:
            work = wintypes.RECT(0, 0, self.winfo_screenwidth(), self.winfo_screenheight())
        return work, ((work.left + work.right) // 2, work.bottom - round(56 * self.scale))

    def fit_rows(self, tag, text, text_font, width, max_rows, *, keep_tail=False):
        line = " ".join(text.splitlines())
        if not line or max_rows < 1:
            return ""
        if text_font.measure(line) <= width:
            return line
        layout = self.layout_items[tag]
        self.surface.itemconfigure(layout, text=line, width=width)
        left, top, _, bottom = self.surface.bbox(layout)
        line_height = text_font.metrics("linespace")
        count = round((bottom - top) / line_height)
        first_row = max(0, count - max_rows)
        if first_row and tag == "previous" and not keep_tail:
            return ""
        indices = [
            self.surface.index(layout, f"@{left - 1},{top + row * line_height + line_height // 2}")
            for row in range(first_row, count)
        ]
        rows = [self.tk.call("string", "range", line, start, stop - 1).rstrip()
                for start, stop in zip(indices, [*indices[1:], self.surface.index(layout, "end")])]
        if len(rows) > 1 and rows[-1] in ("。", "！", "？", "，", "；", "、") and rows[-2]:
            last = rows[-2][-1]
            if 0x4E00 <= ord(last) <= 0x9FFF:
                rows[-2], rows[-1] = rows[-2][:-1], last + rows[-1]
        if first_row:
            first = rows[0]
            while first and text_font.measure(f"…{first}") > width:
                first = first[1:]
            rows[0] = f"…{first.lstrip()}"
        return "\n".join(rows)

    def position_text(self, tag, items, text, x, bottom):
        self.surface.itemconfigure(tag, text=text, state="normal" if text else "hidden")
        for item, (dx, dy) in zip(items, self.stroke_offsets):
            self.surface.coords(item, x + dx, bottom + dy)
        return self.surface.bbox(items[-1]) if text else None

    def release_shrink(self):
        self.shrink_job = None
        self.shrink_ready = True
        self.schedule_watch()

    def cancel_shrink(self):
        if self.shrink_job is not None:
            self.master.after_cancel(self.shrink_job)
            self.shrink_job = None
        self.shrink_ready = False

    def panel_size(self, width, height, max_width, max_height):
        if self.window_bounds is not None and not self.shrink_ready:
            _, _, old_width, old_height = self.window_bounds
            held = min(max_width, max(width, old_width)), min(max_height, max(height, old_height))
            if held != (width, height):
                if self.shrink_job is None:
                    self.shrink_job = self.master.after(SHRINK_DELAY_MS, self.release_shrink)
                return held
        self.cancel_shrink()
        return width, height

    def draw_watch(self):
        self.render_job = None
        if self.drag_origin is not None:
            return

        work, (x, bottom) = self.placement()
        inset = self.gap
        pad = self.padding
        limit = work.right - work.left - 2 * inset
        text_limit = max(1, limit - 2 * pad)
        reserved_height = self.controls.winfo_reqheight() + 4 * self.gap
        spacing = self.caption_font.metrics("linespace")
        previous_spacing = self.previous_font.metrics("linespace")
        work_height = work.bottom - work.top - 2 * inset
        # Reserve part of the work area for the video even when both tracks are long.
        height_limit = min(work_height, max(work_height * 4 // 5, reserved_height + spacing))
        available_height = height_limit - reserved_height
        captions = list(self.lines.values())
        latest = captions[-1] if captions else self.status_message
        earlier = captions[-2] if len(captions) > 1 else ""
        show_original = self.original is not None and not self.interruption
        if show_original:
            earlier = self.original
        if self.interruption:
            latest, earlier = self.interruption, captions[-1] if captions else ""
        max_rows = max(1, available_height // spacing)
        current = self.fit_rows("current", latest, self.caption_font, text_limit, max_rows)
        text_height = (current.count("\n") + 1) * spacing
        # Fit the original into the half-height budget after reserving the translation.
        combined_text_limit = min(available_height, work_height // 2) if show_original else available_height
        previous_rows = (combined_text_limit - text_height - self.gap) // previous_spacing
        if not show_original:
            previous_rows = min(2, previous_rows)
        previous = self.fit_rows("previous", earlier, self.previous_font, text_limit,
                                 previous_rows, keep_tail=show_original)
        height = reserved_height + text_height
        if previous:
            height += (previous.count("\n") + 1) * previous_spacing + self.gap
        current_width = max(self.caption_font.measure(row) for row in current.split("\n"))
        previous_width = max(self.previous_font.measure(row) for row in previous.split("\n"))
        width = min(limit, max(current_width, previous_width, self.controls.winfo_reqwidth()) + 2 * pad)
        self.content_height = height
        width, height = self.panel_size(width, height, limit, max(height, height_limit))

        screen_left, screen_right = work.left + inset, work.right - inset
        center_x = width // 2
        left = max(screen_left, min(x - center_x, screen_right - width))
        top = max(work.top + inset, min(bottom - height, work.bottom - inset - height))

        bounds = (left, top, width, height)
        if bounds != self.window_bounds:
            self.place_frame(bounds)
        self.position_controls(self.motion.value)
        self.surface.itemconfigure(self.current_items[-1], fill=theme.CAPTION_GOLD if self.interruption else theme.CAPTION_TEXT)
        bottom = height - self.gap
        current_box = self.position_text("latest", self.current_items, current, center_x, bottom)
        previous_box = self.position_text("previous", self.previous_items, previous, center_x,
                                          bottom - text_height - self.gap)
        boxes = [box for box in (previous_box, current_box) if box]
        self.watch_area = (min(box[0] for box in boxes), min(box[1] for box in boxes),
                           max(box[2] for box in boxes), max(box[3] for box in boxes)) if boxes else None
        self.draw_shades()

    def draw_shades(self):
        for shade, item in zip(self.shades, (self.previous_items[-1], self.current_items[-1])):
            bounds = self.surface.bbox(item)
            if bounds and self.background == "shade" and not self.hovered:
                left, top, right, bottom = bounds
                self.set_panel_bounds(self.surface, shade, (left - self.gap, top - 2, right + self.gap, bottom + 2),
                                      round(theme.CONTROL_RADIUS * self.scale))
                self.surface.itemconfigure(shade, state="normal")
            else:
                self.surface.itemconfigure(shade, state="hidden")

    def destroy(self):
        self.pause_poll()
        self.cancel_shrink()
        # Detach before Tk destroys the backdrop child, which is the native owner.
        frame = self.frame
        owner = USER32.GetWindow(frame, GW_OWNER)
        if owner and owner == self.backdrop_frame:
            set_window_owner(frame, 0)
        self.backdrop_bitmap.close()
        if self.render_job is not None:
            self.master.after_cancel(self.render_job)
        super().destroy()
