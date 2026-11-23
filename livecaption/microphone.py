"""Windows shared-mode microphone capture, keyed by MMDevice endpoint ID."""

import ctypes as ct
import time
from collections import Counter
from contextlib import ExitStack
from ctypes import wintypes as win
from uuid import UUID


Interface = ct.c_void_p
HRESULT = ct.c_long
UINT32 = ct.c_uint32


class GUID(ct.Structure):
    _fields_ = [("data1", win.DWORD), ("data2", win.WORD), ("data3", win.WORD), ("data4", win.BYTE * 8)]

    @classmethod
    def parse(cls, text):
        return cls.from_buffer_copy(UUID(text).bytes_le)


class PropertyKey(ct.Structure):
    _fields_ = [("format", GUID), ("property", win.DWORD)]


class PropVariant(ct.Structure):
    # The PROPVARIANT union can also hold a counted array (two pointer widths on x64).
    _fields_ = [("type", win.WORD), ("reserved", win.WORD * 3), ("text", ct.c_wchar_p), ("unused", ct.c_void_p)]


class WaveFormat(ct.Structure):
    _pack_ = 1
    _fields_ = [
        ("format", win.WORD), ("channels", win.WORD), ("sample_rate", win.DWORD),
        ("bytes_per_second", win.DWORD), ("block_align", win.WORD),
        ("bits_per_sample", win.WORD), ("extra_size", win.WORD),
    ]


CLSID_DEVICE_ENUMERATOR = GUID.parse("BCDE0395-E52F-467C-8E3D-C4579291692E")
IID_DEVICE_ENUMERATOR = GUID.parse("A95664D2-9614-4F35-A746-DE8DB63617E6")
IID_AUDIO_CLIENT = GUID.parse("1CB9AD4C-DBFA-4C32-B178-C2F568A703B2")
IID_CAPTURE_CLIENT = GUID.parse("C8ADBD64-E71E-48A0-A4DE-185C395CD317")
FRIENDLY_NAME = PropertyKey(GUID.parse("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 14)
CLSCTX_INPROC_SERVER = 1
DEVICE_STATE_ACTIVE = 1
E_CAPTURE = 1
VT_LPWSTR = 31
PCM_FORMAT = WaveFormat(1, 1, 16000, 32000, 2, 16, 0)
SHARED_MODE = 0
AUTO_CONVERT_PCM = 0x80000000
SRC_DEFAULT_QUALITY = 0x08000000
SILENT_PACKET = 2
MICROPHONE_DISCONNECTED = "所选麦克风已断开或停用，请刷新后重新选择。"

ole = ct.WinDLL("ole32")
ole.CoInitializeEx.argtypes = [ct.c_void_p, win.DWORD]
ole.CoInitializeEx.restype = HRESULT
ole.CoUninitialize.argtypes = []
ole.CoUninitialize.restype = None
ole.CoCreateInstance.argtypes = [ct.POINTER(GUID), Interface, win.DWORD, ct.POINTER(GUID), ct.POINTER(Interface)]
ole.CoCreateInstance.restype = HRESULT
ole.CoTaskMemFree.argtypes = [ct.c_void_p]
ole.CoTaskMemFree.restype = None
ole.PropVariantClear.argtypes = [ct.POINTER(PropVariant)]
ole.PropVariantClear.restype = HRESULT


def _check(result):
    if result >= 0:
        return
    code = result & 0xFFFFFFFF
    if code in (0x80070490, 0x88890004, 0x88890026):
        raise RuntimeError(MICROPHONE_DISCONNECTED)
    if code == 0x80070005:
        raise RuntimeError("无法访问麦克风，请在 Windows 隐私设置中允许桌面应用访问麦克风。")
    if code == 0x8889000A:
        raise RuntimeError("麦克风正被其他程序独占，请关闭占用它的程序后重试。")
    if code == 0x88890010:
        raise RuntimeError("Windows 音频服务未运行，请恢复服务后重试。")
    raise RuntimeError(f"麦克风不可用（0x{code:08X}），请检查设备连接和 Windows 麦克风权限。")


def _method(interface, index, result, *types):
    address = ct.cast(interface, ct.POINTER(ct.POINTER(ct.c_void_p)))[0][index]
    return ct.WINFUNCTYPE(result, Interface, *types)(address)


def _call(interface, index, types, *args):
    return _method(interface, index, HRESULT, *types)(interface, *args)


def _release(interface):
    _method(interface, 2, win.ULONG)(interface)


def _interface(stack, parent, index, types, *args):
    child = Interface()
    _check(_call(parent, index, (*types, ct.POINTER(Interface)), *args, ct.byref(child)))
    stack.callback(_release, child)
    return child


def _enumerator(stack):
    result = ole.CoInitializeEx(None, 0)  # COINIT_MULTITHREADED
    if result >= 0:
        stack.callback(ole.CoUninitialize)
    elif result & 0xFFFFFFFF != 0x80010106:  # Thread already initialized in another apartment.
        _check(result)
    enumerator = Interface()
    _check(ole.CoCreateInstance(ct.byref(CLSID_DEVICE_ENUMERATOR), None, CLSCTX_INPROC_SERVER,
                                ct.byref(IID_DEVICE_ENUMERATOR), ct.byref(enumerator)))
    stack.callback(_release, enumerator)
    return enumerator


def _device_info(device):
    ident = ct.c_void_p()
    # IMMDevice::GetId allocates the string with the COM task allocator.
    _check(_call(device, 5, (ct.POINTER(ct.c_void_p),), ct.byref(ident)))
    with ExitStack() as stack:
        stack.callback(ole.CoTaskMemFree, ident)
        properties = _interface(stack, device, 4, (win.DWORD,), 0)  # OpenPropertyStore(STGM_READ)
        value = PropVariant()
        stack.callback(ole.PropVariantClear, ct.byref(value))
        _check(_call(properties, 5, (ct.POINTER(PropertyKey), ct.POINTER(PropVariant)),
                     ct.byref(FRIENDLY_NAME), ct.byref(value)))  # IPropertyStore::GetValue
        name = value.text if value.type == VT_LPWSTR else None
        return (name or "麦克风", ct.wstring_at(ident))


def _require_active(device):
    state = win.DWORD()
    _check(_call(device, 6, (ct.POINTER(win.DWORD),), ct.byref(state)))  # IMMDevice::GetState
    if state.value != DEVICE_STATE_ACTIVE:
        raise RuntimeError(MICROPHONE_DISCONNECTED)


def microphone_sources():
    with ExitStack() as stack:
        enumerator = _enumerator(stack)
        collection = _interface(stack, enumerator, 3, (ct.c_int, win.DWORD), E_CAPTURE, DEVICE_STATE_ACTIVE)
        count = UINT32()
        _check(_call(collection, 3, (ct.POINTER(UINT32),), ct.byref(count)))  # GetCount
        devices = []
        for index in range(count.value):
            with ExitStack() as item:
                device = _interface(item, collection, 4, (UINT32,), index)  # Item
                devices.append(_device_info(device))
    devices.sort(key=lambda entry: (entry[0].casefold(), entry[1]))
    counts = Counter(name.casefold() for name, _ in devices)
    if any(count > 1 for count in counts.values()):
        return {f"{index}. {name}": ident for index, (name, ident) in enumerate(devices, 1)}
    return dict(devices)


class MicrophoneAudio:
    """Read 16 kHz mono PCM from exactly one selected capture endpoint."""

    def __init__(self, endpoint_id):
        self.endpoint_id = endpoint_id

    def __enter__(self):
        with ExitStack() as stack:
            enumerator = _enumerator(stack)
            device = _interface(stack, enumerator, 5, (ct.c_wchar_p,), self.endpoint_id)  # GetDevice
            _require_active(device)
            self.device = device
            self.next_check = time.monotonic() + 0.5
            client = _interface(stack, device, 3, (ct.POINTER(GUID), win.DWORD, ct.c_void_p),
                                ct.byref(IID_AUDIO_CLIENT), CLSCTX_INPROC_SERVER, None)  # Activate
            # Let the Windows audio engine convert the endpoint mix to the service's PCM format.
            _check(_call(client, 3, (ct.c_int, win.DWORD, ct.c_int64, ct.c_int64,
                                     ct.POINTER(WaveFormat), ct.POINTER(GUID)),
                         SHARED_MODE, AUTO_CONVERT_PCM | SRC_DEFAULT_QUALITY, 2_000_000, 0,
                         ct.byref(PCM_FORMAT), None))  # IAudioClient::Initialize
            self.reader = _interface(stack, client, 14, (ct.POINTER(GUID),), ct.byref(IID_CAPTURE_CLIENT))
            _check(_call(client, 10, ()))  # IAudioClient::Start
            stack.callback(_call, client, 11, ())  # Stop before releasing the COM objects.
            self.cleanup = stack.pop_all()
        return self

    def __exit__(self, *exc):
        self.cleanup.close()

    def read(self, last=False):
        now = time.monotonic()
        if now >= self.next_check:
            _require_active(self.device)
            self.next_check = now + 0.5
        packets = bytearray()
        frames = UINT32()
        while True:
            _check(_call(self.reader, 5, (ct.POINTER(UINT32),), ct.byref(frames)))  # GetNextPacketSize
            if not frames.value:
                return bytes(packets)
            data = ct.c_void_p()
            flags = win.DWORD()
            _check(_call(self.reader, 3, (ct.POINTER(ct.c_void_p), ct.POINTER(UINT32), ct.POINTER(win.DWORD),
                                          ct.POINTER(ct.c_uint64), ct.POINTER(ct.c_uint64)),
                         ct.byref(data), ct.byref(frames), ct.byref(flags), None, None))  # GetBuffer
            if not frames.value:
                return bytes(packets)
            try:
                size = frames.value * PCM_FORMAT.block_align
                packets.extend(bytes(size) if flags.value & SILENT_PACKET else ct.string_at(data, size))
            finally:
                _check(_call(self.reader, 4, (UINT32,), frames.value))  # ReleaseBuffer
            if len(packets) > 64000:
                raise RuntimeError("采音积压超过两秒，请重新开始。")
