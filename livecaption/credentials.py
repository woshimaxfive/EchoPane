"""Store the optional Bailian configuration in Windows Credential Manager."""

import ctypes
import json
from ctypes import wintypes


TARGET = "EchoPane/Bailian/Beijing"
CRED_TYPE_GENERIC = 1
CRED_PERSIST_LOCAL_MACHINE = 2
CRED_MAX_CREDENTIAL_BLOB_SIZE = 5 * 512
ERROR_NOT_FOUND = 1168


class Credential(ctypes.Structure):
    _fields_ = [
        ("Flags", wintypes.DWORD),
        ("Type", wintypes.DWORD),
        ("TargetName", wintypes.LPWSTR),
        ("Comment", wintypes.LPWSTR),
        ("LastWritten", wintypes.FILETIME),
        ("CredentialBlobSize", wintypes.DWORD),
        ("CredentialBlob", ctypes.c_void_p),
        ("Persist", wintypes.DWORD),
        ("AttributeCount", wintypes.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", wintypes.LPWSTR),
        ("UserName", wintypes.LPWSTR),
    ]


advapi = ctypes.WinDLL("Advapi32", use_last_error=True)
credential_pointer = ctypes.POINTER(Credential)
advapi.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                            ctypes.POINTER(credential_pointer)]
advapi.CredReadW.restype = wintypes.BOOL
advapi.CredWriteW.argtypes = [credential_pointer, wintypes.DWORD]
advapi.CredWriteW.restype = wintypes.BOOL
advapi.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
advapi.CredDeleteW.restype = wintypes.BOOL
advapi.CredFree.argtypes = [ctypes.c_void_p]
advapi.CredFree.restype = None


def load_credentials():
    stored = credential_pointer()
    if not advapi.CredReadW(TARGET, CRED_TYPE_GENERIC, 0, ctypes.byref(stored)):
        error = ctypes.get_last_error()
        if error == ERROR_NOT_FOUND:
            return "", ""
        raise ctypes.WinError(error)
    try:
        blob = ctypes.string_at(stored.contents.CredentialBlob, stored.contents.CredentialBlobSize)
        values = json.loads(blob.decode("utf-8"))
        if not isinstance(values, list) or len(values) != 2 or not all(isinstance(value, str) for value in values):
            raise ValueError("凭据格式有误。")
        return tuple(values)
    finally:
        advapi.CredFree(stored)


def save_credentials(key, workspace):
    blob = json.dumps([key, workspace], ensure_ascii=False).encode("utf-8")
    if len(blob) > CRED_MAX_CREDENTIAL_BLOB_SIZE:
        raise ValueError("Key 或业务空间 ID 过长。")
    buffer = ctypes.create_string_buffer(blob)
    entry = Credential(Type=CRED_TYPE_GENERIC, TargetName=TARGET, CredentialBlobSize=len(blob),
                       CredentialBlob=ctypes.addressof(buffer), Persist=CRED_PERSIST_LOCAL_MACHINE)
    if not advapi.CredWriteW(ctypes.byref(entry), 0):
        raise ctypes.WinError(ctypes.get_last_error())


def clear_credentials():
    if not advapi.CredDeleteW(TARGET, CRED_TYPE_GENERIC, 0):
        error = ctypes.get_last_error()
        if error != ERROR_NOT_FOUND:
            raise ctypes.WinError(error)
