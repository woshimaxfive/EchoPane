"""Extend the main window's client area into its Windows caption."""

import ctypes
from ctypes import wintypes

from native_windows import SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER, USER32


WM_NCCALCSIZE = 0x0083
WM_NCHITTEST = 0x0084
WM_NCDESTROY = 0x0082
HTCLIENT = 1
SWP_NOMOVE = 0x0002
SWP_FRAMECHANGED = 0x0020
DWMWA_BORDER_COLOR = 34
DWMWA_COLOR_NONE = 0xFFFFFFFE

SubclassProc = ctypes.WINFUNCTYPE(
    ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, ctypes.c_size_t,
    ctypes.c_ssize_t, ctypes.c_size_t, ctypes.c_size_t,
)
COMCTL32 = ctypes.WinDLL("comctl32", use_last_error=True)
COMCTL32.SetWindowSubclass.argtypes = (wintypes.HWND, SubclassProc, ctypes.c_size_t, ctypes.c_size_t)
COMCTL32.SetWindowSubclass.restype = wintypes.BOOL
COMCTL32.RemoveWindowSubclass.argtypes = (wintypes.HWND, SubclassProc, ctypes.c_size_t)
COMCTL32.RemoveWindowSubclass.restype = wintypes.BOOL
COMCTL32.DefSubclassProc.argtypes = (wintypes.HWND, wintypes.UINT, ctypes.c_size_t, ctypes.c_ssize_t)
COMCTL32.DefSubclassProc.restype = ctypes.c_ssize_t
USER32.GetClientRect.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.RECT))
USER32.GetClientRect.restype = wintypes.BOOL
USER32.ScreenToClient.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.POINT))
USER32.ScreenToClient.restype = wintypes.BOOL
USER32.IsZoomed.argtypes = (wintypes.HWND,)
USER32.IsZoomed.restype = wintypes.BOOL
DWMAPI = ctypes.WinDLL("dwmapi")
DWMAPI.DwmSetWindowAttribute.argtypes = (wintypes.HWND, wintypes.DWORD, ctypes.c_void_p, wintypes.DWORD)
DWMAPI.DwmSetWindowAttribute.restype = wintypes.LONG


class WindowFrame:
    def __init__(self, window):
        self.window = window
        self.handle = None
        self.drag_origin = None
        self.callback = SubclassProc(self.handle_message)
        self.subclass_id = id(self)

    def attach(self):
        if self.window.overrideredirect():
            return False
        frame = int(self.window.wm_frame(), 0)
        if frame == self.window.winfo_id():
            return False
        if not COMCTL32.SetWindowSubclass(frame, self.callback, self.subclass_id, 0):
            return False
        flags = SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
        if USER32.SetWindowPos(frame, None, 0, 0, 0, 0, flags):
            self.handle = frame
            color = wintypes.DWORD(DWMWA_COLOR_NONE)
            DWMAPI.DwmSetWindowAttribute(frame, DWMWA_BORDER_COLOR, ctypes.byref(color), ctypes.sizeof(color))
            return True
        COMCTL32.RemoveWindowSubclass(frame, self.callback, self.subclass_id)
        return False

    def begin_drag(self, event):
        bounds = wintypes.RECT()
        if USER32.GetWindowRect(self.handle, ctypes.byref(bounds)):
            self.drag_origin = event.x_root, event.y_root, bounds

    def drag(self, event):
        if self.drag_origin is None:
            return
        x, y, bounds = self.drag_origin
        dx, dy = event.x_root - x, event.y_root - y
        if not (dx or dy):
            return
        left, top = bounds.left + dx, bounds.top + dy
        if USER32.IsZoomed(self.handle):
            if max(abs(dx), abs(dy)) < 4:
                return
            # On restore, keep the pointer over the same part of the title row.
            fraction = (x - bounds.left) / (bounds.right - bounds.left)
            self.window.state("normal")
            restored = wintypes.RECT()
            if not USER32.GetWindowRect(self.handle, ctypes.byref(restored)):
                return
            width, height = restored.right - restored.left, restored.bottom - restored.top
            left = event.x_root - round(fraction * width)
            self.drag_origin = event.x_root, event.y_root, wintypes.RECT(left, top, left + width, top + height)
        USER32.SetWindowPos(self.handle, None, left, top, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)

    def finish_drag(self, _event=None):
        self.drag_origin = None

    def handle_message(self, handle, message, wparam, lparam, subclass_id, _data):
        if message == WM_NCCALCSIZE and lparam:
            # The RECT is first in NCCALCSIZE_PARAMS and is the entire argument when wParam is zero.
            rect = ctypes.cast(lparam, ctypes.POINTER(wintypes.RECT)).contents
            top, left = rect.top, rect.left
            COMCTL32.DefSubclassProc(handle, message, wparam, lparam)
            # A maximized frame overhangs the work area by the size of its resize border.
            rect.top = top + (rect.left - left if USER32.IsZoomed(handle) else 0)
            return 0
        if message == WM_NCHITTEST:
            point = wintypes.POINT(ctypes.c_int16(lparam & 0xFFFF).value,
                                  ctypes.c_int16((lparam >> 16) & 0xFFFF).value)
            client = wintypes.RECT()
            if USER32.ScreenToClient(handle, ctypes.byref(point)) and USER32.GetClientRect(
                handle, ctypes.byref(client)
            ):
                # Let Tk receive client presses. Windows still owns the outer resize border.
                if 0 <= point.x < client.right and 0 <= point.y < client.bottom:
                    return HTCLIENT
        if message == WM_NCDESTROY:
            self.handle = None
            self.finish_drag()
            COMCTL32.RemoveWindowSubclass(handle, self.callback, subclass_id)
        return COMCTL32.DefSubclassProc(handle, message, wparam, lparam)
