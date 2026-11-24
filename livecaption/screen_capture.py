"""Select and capture a rectangle in Windows virtual desktop coordinates."""

import ctypes
import tkinter as tk
from contextlib import contextmanager
from ctypes import wintypes

import numpy as np

import theme
from native_windows import BitmapHeader, GDI32, SWP_NOACTIVATE, SWP_NOZORDER, USER32, monitor_work_area
from window_frame import DWMAPI, set_window_transitions


USER32.GetSystemMetrics.argtypes = (ctypes.c_int,)
USER32.GetSystemMetrics.restype = ctypes.c_int
MonitorEnumProc = ctypes.WINFUNCTYPE(
    wintypes.BOOL, wintypes.HANDLE, wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM,
)
USER32.EnumDisplayMonitors.argtypes = (wintypes.HDC, ctypes.POINTER(wintypes.RECT), MonitorEnumProc, wintypes.LPARAM)
USER32.EnumDisplayMonitors.restype = wintypes.BOOL
USER32.SetThreadDpiAwarenessContext.argtypes = (wintypes.HANDLE,)
USER32.SetThreadDpiAwarenessContext.restype = wintypes.HANDLE
USER32.GetDC.argtypes = (wintypes.HWND,)
USER32.GetDC.restype = wintypes.HDC
USER32.ReleaseDC.argtypes = (wintypes.HWND, wintypes.HDC)
USER32.ReleaseDC.restype = ctypes.c_int
GDI32.BitBlt.argtypes = (
    wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD,
)
GDI32.BitBlt.restype = wintypes.BOOL
GDI32.GdiFlush.argtypes = ()
GDI32.GdiFlush.restype = wintypes.BOOL
DWMAPI.DwmFlush.argtypes = ()
DWMAPI.DwmFlush.restype = wintypes.LONG

VIRTUAL_SCREEN_METRICS = (76, 77, 78, 79)
PER_MONITOR_AWARE_V2 = -4
COPY_SCREEN = 0x40CC0020  # SRCCOPY | CAPTUREBLT
MIN_SIDE = 8
MAX_PIXELS = 40_000_000
CAPTURE_SETTLE_MS = 45


@contextmanager
def physical_coordinates():
    previous = USER32.SetThreadDpiAwarenessContext(PER_MONITOR_AWARE_V2)
    if not previous:
        raise ctypes.WinError()
    try:
        yield
    finally:
        USER32.SetThreadDpiAwarenessContext(previous)


def virtual_screen():
    with physical_coordinates():
        return tuple(USER32.GetSystemMetrics(metric) for metric in VIRTUAL_SCREEN_METRICS)


def display_layout():
    bounds = []

    @MonitorEnumProc
    def collect(_monitor, _dc, rectangle, _data):
        area = rectangle.contents
        bounds.append((area.left, area.top, area.right, area.bottom))
        return True

    with physical_coordinates():
        if not USER32.EnumDisplayMonitors(None, None, collect, 0) or not bounds:
            raise OSError("The Windows display layout is unavailable.")
    return tuple(sorted(bounds))


def cursor_position():
    point = wintypes.POINT()
    # Tk's event callback may run with a different DPI context from the capture.
    with physical_coordinates():
        if not USER32.GetCursorPos(ctypes.byref(point)):
            raise ctypes.WinError()
    return point.x, point.y


def selected_rectangle(start, end, desktop):
    left, top, width, height = desktop
    x1, x2 = sorted((start[0], end[0]))
    y1, y2 = sorted((start[1], end[1]))
    x, y = max(left, x1), max(top, y1)
    width, height = min(left + width, x2) - x, min(top + height, y2) - y
    return x, y, width, height


def capture_region(rectangle):
    left, top, width, height = rectangle
    with physical_coordinates():
        DWMAPI.DwmFlush()
        screen = USER32.GetDC(None)
        if not screen:
            raise ctypes.WinError()
        dc = bitmap = original = None
        try:
            dc = GDI32.CreateCompatibleDC(screen)
            if not dc:
                raise ctypes.WinError()
            header = BitmapHeader(ctypes.sizeof(BitmapHeader), width, -height, 1, 32)
            address = ctypes.c_void_p()
            bitmap = GDI32.CreateDIBSection(dc, ctypes.byref(header), 0, ctypes.byref(address), None, 0)
            if not bitmap or not address.value:
                raise ctypes.WinError()
            original = GDI32.SelectObject(dc, bitmap)
            if not original or original == ctypes.c_void_p(-1).value:
                original = None
                raise ctypes.WinError()
            if not GDI32.BitBlt(dc, 0, 0, width, height, screen, left, top, COPY_SCREEN):
                raise ctypes.WinError()
            GDI32.GdiFlush()
            bgra = np.ctypeslib.as_array((ctypes.c_uint8 * (width * height * 4)).from_address(address.value))
            return bgra.reshape(height, width, 4)[:, :, :3].copy()
        finally:
            if original:
                GDI32.SelectObject(dc, original)
            if bitmap:
                GDI32.DeleteObject(bitmap)
            if dc:
                GDI32.DeleteDC(dc)
            USER32.ReleaseDC(None, screen)


class RegionSelector(tk.Toplevel):
    def __init__(self, root, completed):
        super().__init__(root)
        self.withdraw()
        self.completed = completed
        self.start = self.visual_start = None
        self.finishing = False
        self.overrideredirect(True)
        self.attributes("-topmost", True)
        self.attributes("-alpha", 0.42)
        self.canvas = tk.Canvas(self, bg=theme.CAPTION_BG, bd=0, highlightthickness=0, cursor="crosshair")
        self.canvas.pack(fill="both", expand=True)
        self.outline = self.canvas.create_rectangle(0, 0, 0, 0, outline="white", width=3, state="hidden")
        self.bind("<Escape>", lambda _event: self.finish(status="已取消框选。"))
        self.canvas.bind("<Button-3>", lambda _event: self.finish(status="已取消框选。"))
        self.canvas.bind("<ButtonPress-1>", self.press)
        self.canvas.bind("<B1-Motion>", self.move)
        self.canvas.bind("<ButtonRelease-1>", self.release)

    def show(self):
        self.layout = display_layout()
        self.desktop = virtual_screen()
        left, top, width, height = self.desktop
        if width <= 0 or height <= 0:
            raise OSError("The Windows virtual desktop is unavailable.")
        self.geometry(f"{width}x{height}+0+0")
        self.deiconify()
        self.update_idletasks()
        set_window_transitions(self, disabled=True)
        frame = int(self.wm_frame(), 0)
        with physical_coordinates():
            if not USER32.SetWindowPos(frame, None, *self.desktop, SWP_NOZORDER | SWP_NOACTIVATE):
                raise ctypes.WinError()
            x, y = cursor_position()
            work = monitor_work_area((x, y, 1, 1))
        center, upper = ((work.left + work.right) // 2, work.top) if work else (left + width // 2, top)
        self.canvas.create_text(center - left, upper - top + 28, text="拖动选取区域   Esc 取消",
                                fill="white", font=(theme.FONT, 13, "bold"))
        self.focus_force()
        self.grab_set()

    def press(self, event):
        try:
            self.start = cursor_position()
        except OSError:
            self.finish(status="无法读取鼠标位置，请重新框选。")
            return
        self.visual_start = event.x, event.y
        self.canvas.coords(self.outline, event.x, event.y, event.x, event.y)
        self.canvas.itemconfigure(self.outline, state="normal")

    def move(self, event):
        if self.visual_start is not None:
            self.canvas.coords(self.outline, *self.visual_start, event.x, event.y)

    def release(self, _event):
        if self.start is None:
            return
        try:
            rectangle = selected_rectangle(self.start, cursor_position(), self.desktop)
        except OSError:
            self.finish(status="无法读取鼠标位置，请重新框选。")
            return
        _, _, width, height = rectangle
        if min(width, height) < MIN_SIDE:
            self.finish(status="选区太小，请拖动框住文字。")
        elif width * height > MAX_PIXELS:
            self.finish(status="选区太大，请缩小到有文字的区域。")
        else:
            self.finish(rectangle)

    def finish(self, rectangle=None, *, status=""):
        if self.finishing:
            return
        self.finishing = True
        self.grab_release()
        self.withdraw()
        # Leave time for the selector to disappear from the composed desktop.
        self.after(CAPTURE_SETTLE_MS, self.complete, rectangle, status)

    def complete(self, rectangle, status):
        selection = (rectangle, self.layout) if rectangle is not None else None
        self.destroy()
        self.completed(selection, status)
