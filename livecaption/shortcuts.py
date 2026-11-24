"""Receive Windows global keyboard shortcuts on the Tk window thread."""

from collections import deque
from ctypes import c_int, wintypes
from dataclasses import dataclass
from string import ascii_uppercase, digits

from native_windows import USER32
from preferences import load_shortcut_preferences, save_shortcut_preferences
from window_frame import COMCTL32, SubclassProc, WM_NCDESTROY


WM_HOTKEY = 0x0312
MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004
MOD_NOREPEAT = 0x4000
VK_F1 = 0x70
DISPATCH_MS = 50

SHORTCUTS = {
    "overlay": ("浮窗显隐", "Ctrl+Alt+F7"),
    "history": ("字幕回看", "Ctrl+Alt+F9"),
    "screen_select": ("框选屏幕", "Ctrl+Alt+F6"),
    "screen_reuse": ("复用上次选区", "Ctrl+Alt+F10"),
}
MODIFIERS = {"Ctrl": MOD_CONTROL, "Alt": MOD_ALT, "Shift": MOD_SHIFT}
MODIFIER_CODES = {name.casefold(): code for name, code in MODIFIERS.items()}
FUNCTION_KEYS = {VK_F1 + i - 1: f"F{i}" for i in range(1, 25) if i != 12}
KEY_NAMES = {
    **{ord(key): key for key in ascii_uppercase + digits},
    **FUNCTION_KEYS,
    0x08: "Backspace", 0x09: "Tab", 0x0D: "Enter", 0x1B: "Esc", 0x20: "Space",
    0x21: "PageUp", 0x22: "PageDown", 0x23: "End", 0x24: "Home",
    0x25: "Left", 0x26: "Up", 0x27: "Right", 0x28: "Down", 0x2D: "Insert", 0x2E: "Delete",
}
KEY_CODES = {name.casefold(): code for code, name in KEY_NAMES.items()}
INVALID_HOTKEY = "请使用功能键，或用 Ctrl、Alt、Shift 搭配字母、数字、功能键或导航键。"

USER32.RegisterHotKey.argtypes = (wintypes.HWND, c_int, wintypes.UINT, wintypes.UINT)
USER32.RegisterHotKey.restype = wintypes.BOOL
USER32.UnregisterHotKey.argtypes = (wintypes.HWND, c_int)
USER32.UnregisterHotKey.restype = wintypes.BOOL


@dataclass(frozen=True)
class Shortcut:
    modifiers: int
    key: int

    @property
    def ident(self):
        # Each supported chord has an ID in the application's Win32 range.
        return (self.modifiers << 8) | self.key

    def __str__(self):
        names = [name for name, code in MODIFIERS.items() if self.modifiers & code]
        return "+".join((*names, KEY_NAMES[self.key]))


def shortcut_for_key(modifiers, key):
    if key not in KEY_NAMES or (not modifiers and key not in FUNCTION_KEYS):
        raise ValueError(INVALID_HOTKEY)
    return Shortcut(modifiers, key)


def parse_shortcut(value):
    if value is None or isinstance(value, str) and not value.strip():
        return None
    if not isinstance(value, str):
        raise ValueError(INVALID_HOTKEY)
    *modifiers, key = (part.strip().casefold() for part in value.split("+"))
    if len(set(modifiers)) != len(modifiers) or any(part not in MODIFIER_CODES for part in modifiers):
        raise ValueError(INVALID_HOTKEY)
    return shortcut_for_key(sum(MODIFIER_CODES[part] for part in modifiers), KEY_CODES.get(key))


class GlobalShortcuts:
    def __init__(self, window, actions):
        self.window = window
        self.actions = actions
        self.bindings = {}
        self.routes = {}
        self.recorder = None
        self.pending = deque()
        self.timer = None
        self.callback = SubclassProc(self.handle_message)
        self.subclass_id = id(self)
        frame = int(window.wm_frame(), 0)
        self.handle = frame if COMCTL32.SetWindowSubclass(frame, self.callback, self.subclass_id, 0) else None
        self.window.bind("<Destroy>", self.cancel_timer, add="+")
        preferences = load_shortcut_preferences()
        for name, (_label, default) in SHORTCUTS.items():
            try:
                chord = parse_shortcut(preferences.get(name, default))
            except ValueError:
                chord = parse_shortcut(default)
            # A new default must yield to a binding saved by an earlier version.
            if name not in preferences and chord in self.bindings.values():
                chord = None
            self.bindings[name] = chord
            if chord is not None and chord.ident not in self.routes and self.claim(chord):
                self.routes[chord.ident] = name
        self.update_timer()

    def claim(self, chord):
        return self.handle and USER32.RegisterHotKey(self.handle, chord.ident, chord.modifiers | MOD_NOREPEAT, chord.key)

    def available(self, name):
        chord = self.bindings[name]
        return chord is not None and self.routes.get(chord.ident) == name

    def apply(self, bindings):
        routes = {}
        for name, chord in bindings.items():
            if chord is None:
                continue
            if chord.ident in routes:
                first = SHORTCUTS[routes[chord.ident]][0]
                second = SHORTCUTS[name][0]
                raise ValueError(f"「{first}」和「{second}」选择了同一个组合 {chord}。")
            routes[chord.ident] = name

        staged = []
        unavailable = []
        try:
            for ident, name in routes.items():
                if ident in self.routes:
                    continue
                chord = bindings[name]
                if self.claim(chord):
                    staged.append(ident)
                elif self.bindings[name] == chord:
                    unavailable.append(ident)
                else:
                    raise ValueError(f"{chord} 已被占用或无法注册，请为「{SHORTCUTS[name][0]}」换一个组合。")
            save_shortcut_preferences({name: str(chord) if chord is not None else None for name, chord in bindings.items()})
        except (OSError, ValueError):
            for ident in staged:
                USER32.UnregisterHotKey(self.handle, ident)
            raise

        for ident in self.routes.keys() - routes.keys():
            USER32.UnregisterHotKey(self.handle, ident)
        for ident in unavailable:
            del routes[ident]
        self.bindings = dict(bindings)
        self.routes = routes
        self.pending.clear()
        self.update_timer()

    def handle_message(self, handle, message, wparam, lparam, subclass_id, _data):
        if message == WM_HOTKEY and wparam in self.routes:
            # The native callback may run inside Tk's event loop. Let Tk invoke
            # the queued action from its own timer instead of re-entering Tcl here.
            self.pending.append(wparam)
            return 0
        if message == WM_NCDESTROY:
            for ident in self.routes:
                USER32.UnregisterHotKey(handle, ident)
            self.routes.clear()
            self.pending.clear()
            self.handle = None
            COMCTL32.RemoveWindowSubclass(handle, self.callback, subclass_id)
        return COMCTL32.DefSubclassProc(handle, message, wparam, lparam)

    def update_timer(self):
        if self.routes and self.timer is None:
            self.timer = self.window.after(DISPATCH_MS, self.dispatch)
        elif not self.routes and self.timer is not None:
            self.window.after_cancel(self.timer)
            self.timer = None

    def dispatch(self):
        self.timer = None
        self.update_timer()
        while self.pending:
            name = self.routes.get(self.pending.popleft())
            if name is not None and not (self.recorder and self.recorder(self.bindings[name])):
                self.actions[name]()

    def cancel_timer(self, event):
        if event.widget is self.window and self.timer is not None:
            self.window.after_cancel(self.timer)
            self.timer = None
