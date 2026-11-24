"""Windows coordinates and styles used by the caption surfaces."""

import ctypes
from ctypes import wintypes


USER32 = ctypes.WinDLL("user32", use_last_error=True)
GDI32 = ctypes.WinDLL("gdi32", use_last_error=True)
USER32.GetWindowLongW.argtypes = (wintypes.HWND, ctypes.c_int)
USER32.GetWindowLongW.restype = wintypes.LONG
USER32.SetWindowLongW.argtypes = (wintypes.HWND, ctypes.c_int, wintypes.LONG)
USER32.SetWindowLongW.restype = wintypes.LONG
USER32.SetWindowLongPtrW.argtypes = (wintypes.HWND, ctypes.c_int, ctypes.c_ssize_t)
USER32.SetWindowLongPtrW.restype = ctypes.c_ssize_t
USER32.GetWindow.argtypes = (wintypes.HWND, wintypes.UINT)
USER32.GetWindow.restype = wintypes.HWND
USER32.GetWindowRect.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.RECT))
USER32.GetWindowRect.restype = wintypes.BOOL
USER32.SetWindowPos.argtypes = (wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, wintypes.UINT)
USER32.SetWindowPos.restype = wintypes.BOOL
USER32.GetCursorPos.argtypes = (ctypes.POINTER(wintypes.POINT),)
USER32.GetCursorPos.restype = wintypes.BOOL
USER32.SystemParametersInfoW.argtypes = (wintypes.UINT, wintypes.UINT, ctypes.c_void_p, wintypes.UINT)
USER32.SystemParametersInfoW.restype = wintypes.BOOL
USER32.MonitorFromRect.argtypes = (ctypes.POINTER(wintypes.RECT), wintypes.DWORD)
USER32.MonitorFromRect.restype = wintypes.HANDLE
USER32.MonitorFromWindow.argtypes = (wintypes.HWND, wintypes.DWORD)
USER32.MonitorFromWindow.restype = wintypes.HANDLE

GWL_EXSTYLE = -20
GWLP_HWNDPARENT = -8
GW_OWNER = 4
WS_EX_TRANSPARENT = 0x20
WS_EX_LAYERED = 0x00080000
WS_EX_NOACTIVATE = 0x08000000
SWP_NOSIZE = 0x0001
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010
MONITOR_DEFAULTTONEAREST = 2
SPI_GETCLIENTAREAANIMATION = 0x1042
ULW_ALPHA = 0x00000002


class BitmapHeader(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("width", wintypes.LONG), ("height", wintypes.LONG),
                ("planes", wintypes.WORD), ("bits", wintypes.WORD), ("compression", wintypes.DWORD),
                ("image_size", wintypes.DWORD), ("x_density", wintypes.LONG), ("y_density", wintypes.LONG),
                ("used", wintypes.DWORD), ("important", wintypes.DWORD)]


class BlendFunction(ctypes.Structure):
    _fields_ = [("operation", ctypes.c_ubyte), ("flags", ctypes.c_ubyte),
                ("opacity", ctypes.c_ubyte), ("format", ctypes.c_ubyte)]


GDI32.CreateCompatibleDC.argtypes = (wintypes.HDC,)
GDI32.CreateCompatibleDC.restype = wintypes.HDC
GDI32.CreateDIBSection.argtypes = (wintypes.HDC, ctypes.POINTER(BitmapHeader), wintypes.UINT,
                                  ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE, wintypes.DWORD)
GDI32.CreateDIBSection.restype = wintypes.HBITMAP
GDI32.SelectObject.argtypes = (wintypes.HDC, wintypes.HANDLE)
GDI32.SelectObject.restype = wintypes.HANDLE
GDI32.DeleteObject.argtypes = (wintypes.HANDLE,)
GDI32.DeleteDC.argtypes = (wintypes.HDC,)
USER32.UpdateLayeredWindow.argtypes = (
    wintypes.HWND, wintypes.HDC, ctypes.POINTER(wintypes.POINT), ctypes.POINTER(wintypes.SIZE),
    wintypes.HDC, ctypes.POINTER(wintypes.POINT), wintypes.DWORD, ctypes.POINTER(BlendFunction), wintypes.DWORD,
)
USER32.UpdateLayeredWindow.restype = wintypes.BOOL


class LayeredBitmap:
    """Hold one bitmap while the same surface is moved or faded."""

    def __init__(self):
        self.dc = None
        self.bitmap = None
        self.original = None
        self.size = None

    def replace(self, pixels):
        height, width = pixels.shape[:2]
        if self.dc is None:
            self.dc = GDI32.CreateCompatibleDC(None)
            if not self.dc:
                raise ctypes.WinError()
        header = BitmapHeader(ctypes.sizeof(BitmapHeader), width, -height, 1, 32)
        address = ctypes.c_void_p()
        bitmap = GDI32.CreateDIBSection(self.dc, ctypes.byref(header), 0, ctypes.byref(address), None, 0)
        if not bitmap:
            raise ctypes.WinError()
        if not address.value:
            GDI32.DeleteObject(bitmap)
            raise OSError("The layered bitmap has no pixel storage.")
        ctypes.memmove(address, pixels.ctypes.data, pixels.nbytes)
        previous = GDI32.SelectObject(self.dc, bitmap)
        if not previous or previous == ctypes.c_void_p(-1).value:
            error = ctypes.get_last_error()
            GDI32.DeleteObject(bitmap)
            raise ctypes.WinError(error)
        if self.bitmap is None:
            self.original = previous
        else:
            GDI32.DeleteObject(previous)
        self.bitmap = bitmap
        self.size = width, height

    def present(self, window, x, y, opacity):
        origin = wintypes.POINT()
        position = wintypes.POINT(x, y)
        size = wintypes.SIZE(*self.size)
        blend = BlendFunction(0, 0, round(255 * opacity), 1)  # AC_SRC_OVER, AC_SRC_ALPHA
        if not USER32.UpdateLayeredWindow(window, None, ctypes.byref(position), ctypes.byref(size),
                                          self.dc, ctypes.byref(origin), 0, ctypes.byref(blend), ULW_ALPHA):
            raise ctypes.WinError()

    def close(self):
        if self.bitmap is not None:
            GDI32.SelectObject(self.dc, self.original)
            GDI32.DeleteObject(self.bitmap)
        if self.dc is not None:
            GDI32.DeleteDC(self.dc)
        self.dc = self.bitmap = self.original = self.size = None


class MonitorInfo(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("monitor", wintypes.RECT),
                ("work", wintypes.RECT), ("flags", wintypes.DWORD)]


USER32.GetMonitorInfoW.argtypes = (wintypes.HANDLE, ctypes.POINTER(MonitorInfo))
USER32.GetMonitorInfoW.restype = wintypes.BOOL


def animations_enabled():
    enabled = wintypes.BOOL(True)
    USER32.SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, ctypes.byref(enabled), 0)
    return bool(enabled.value)


def set_mouse_passthrough(window, enabled):
    style = USER32.GetWindowLongW(window, GWL_EXSTYLE)
    updated = style | WS_EX_TRANSPARENT if enabled else style & ~WS_EX_TRANSPARENT
    if updated != style:
        USER32.SetWindowLongW(window, GWL_EXSTYLE, updated)


def set_window_owner(window, owner):
    ctypes.set_last_error(0)
    previous = USER32.SetWindowLongPtrW(window, GWLP_HWNDPARENT, owner)
    if not previous and (error := ctypes.get_last_error()):
        raise ctypes.WinError(error)


def monitor_work_area(bounds, *, nearest=True):
    left, top, width, height = bounds
    rect = wintypes.RECT(left, top, left + width, top + height)
    flags = MONITOR_DEFAULTTONEAREST if nearest else 0
    return get_work_area(USER32.MonitorFromRect(ctypes.byref(rect), flags))


def window_work_area(window):
    return get_work_area(USER32.MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST))


def get_work_area(monitor):
    info = MonitorInfo(size=ctypes.sizeof(MonitorInfo))
    if monitor and USER32.GetMonitorInfoW(monitor, ctypes.byref(info)):
        return info.work
    return None
