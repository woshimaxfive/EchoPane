#include "subtitle_overlay.h"
#include <windowsx.h>
#include <dwmapi.h>
#include <algorithm>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
constexpr wchar_t kClass[] = L"EchoPaneSubtitleOverlay";
constexpr int kHotkey = 0x5E01;
constexpr int kMaximumWidth = 2400;
constexpr int kMaximumHeight = 1200;
int Integer(const flutter::EncodableMap& map, const char* name) {
  const auto& value = map.at(flutter::EncodableValue(name));
  if (const auto* integer = std::get_if<int32_t>(&value)) return *integer;
  throw std::runtime_error("Invalid overlay dimensions");
}
HMONITOR Monitor(const flutter::EncodableValue& value) {
  const auto id = std::holds_alternative<int64_t>(value) ? std::get<int64_t>(value) : std::get<int32_t>(value);
  return reinterpret_cast<HMONITOR>(static_cast<intptr_t>(id));
}
}

SubtitleOverlay::SubtitleOverlay(flutter::FlutterEngine* engine, HWND main_window)
    : main_window_(main_window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(engine->messenger(),
      "echopane/subtitle_overlay", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
}

SubtitleOverlay::~SubtitleOverlay() {
  channel_->SetMethodCallHandler(nullptr);
  if (window_) {
    KillTimer(window_, 1);
    if (hotkey_) UnregisterHotKey(window_, kHotkey);
    SetWindowLongPtr(window_, GWLP_USERDATA, 0);
    DestroyWindow(window_);
  }
}

void SubtitleOverlay::EnsureWindow() {
  if (window_) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    throw std::runtime_error("Overlay class registration failed");
  window_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
      WS_EX_TOPMOST, kClass, L"EchoPane · 悬浮字幕", WS_POPUP | WS_THICKFRAME,
      0, 0, 720, 220, nullptr, nullptr, wc.hInstance, this);
  if (!window_) throw std::runtime_error("Overlay creation failed");
  if (!SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE)) {
    SetWindowLongPtr(window_, GWLP_USERDATA, 0);
    DestroyWindow(window_);
    window_ = nullptr;
    throw std::runtime_error("Overlay capture exclusion failed");
  }
  hotkey_ = RegisterHotKey(window_, kHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'S') != 0;
  Place(MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST));
}

void SubtitleOverlay::Place(HMONITOR monitor) {
  MONITORINFO info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(monitor, &info))
    throw std::runtime_error("Overlay monitor unavailable");
  const int dpi = static_cast<int>(GetDpiForWindow(window_));
  const int width = std::min({MulDiv(720, dpi, 96), kMaximumWidth,
      static_cast<int>(info.rcWork.right - info.rcWork.left)});
  const int height = std::min({MulDiv(220, dpi, 96), kMaximumHeight,
      static_cast<int>(info.rcWork.bottom - info.rcWork.top)});
  SetWindowPos(window_, HWND_TOPMOST,
      info.rcWork.left + (info.rcWork.right - info.rcWork.left - width) / 2,
      std::max(static_cast<int>(info.rcWork.top), static_cast<int>(info.rcWork.bottom) - height - MulDiv(48, dpi, 96)),
      width, height, SWP_NOACTIVATE);
}

bool SubtitleOverlay::Lock(bool locked) {
  auto style = GetWindowLongPtr(window_, GWL_EXSTYLE);
  style = locked ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT;
  SetLastError(0);
  if (!SetWindowLongPtr(window_, GWL_EXSTYLE, style) && GetLastError() != 0)
    return false;
  locked_ = locked;
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  return true;
}

SubtitleOverlay::Map SubtitleOverlay::Snapshot() const {
  RECT bounds{};
  if (window_) GetWindowRect(window_, &bounds);
  DWORD affinity = 0;
  if (window_) GetWindowDisplayAffinity(window_, &affinity);
  return {
    {Value("visible"), Value(window_ && IsWindowVisible(window_) != 0)},
    {Value("locked"), Value(locked_)}, {Value("hotkey"), Value(hotkey_)},
    {Value("width"), Value(static_cast<int>(bounds.right - bounds.left))},
    {Value("height"), Value(static_cast<int>(bounds.bottom - bounds.top))},
    {Value("x"), Value(static_cast<int>(bounds.left))},
    {Value("y"), Value(static_cast<int>(bounds.top))},
    {Value("dpi"), Value(window_ ? static_cast<int>(GetDpiForWindow(window_)) : 96)},
    {Value("excluded"), Value(affinity == WDA_EXCLUDEFROMCAPTURE)},
    {Value("topmost"), Value(window_ && (GetWindowLongPtr(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0)},
    {Value("transparent"), Value(window_ && (GetWindowLongPtr(window_, GWL_EXSTYLE) & WS_EX_TRANSPARENT) != 0)},
    {Value("frames"), Value(rendered_frames_)}
  };
}

void SubtitleOverlay::Notify() {
  channel_->InvokeMethod("state", std::make_unique<Value>(Snapshot()));
}

void SubtitleOverlay::Handle(const flutter::MethodCall<Value>& call,
    std::unique_ptr<flutter::MethodResult<Value>> result) {
  try {
    const auto& method = call.method_name();
    if (method == "state") {
      result->Success(Value(Snapshot()));
    } else if (method == "configure") {
      const auto& args = std::get<Map>(*call.arguments());
      const bool visible = std::get<bool>(args.at(Value("visible")));
      if (visible) {
        EnsureWindow();
        if (!hotkey_) hotkey_ = RegisterHotKey(window_, kHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'S') != 0;
        if (std::get<bool>(args.at(Value("restore")))) {
          HMONITOR monitor = MonitorFromWindow(main_window_, MONITOR_DEFAULTTONEAREST);
          if (const auto id = args.find(Value("displayId")); id != args.end()) {
            auto candidate = Monitor(id->second);
            MONITORINFO info{sizeof(MONITORINFO)};
            if (GetMonitorInfo(candidate, &info)) monitor = candidate;
          }
          Place(monitor);
        }
        if (!Lock(std::get<bool>(args.at(Value("locked")))))
          throw std::runtime_error("Overlay input style update failed");
        SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
      } else if (window_) {
        ShowWindow(window_, SW_HIDE);
        Lock(false);
        if (hotkey_) { UnregisterHotKey(window_, kHotkey); hotkey_ = false; }
      }
      result->Success(Value(Snapshot()));
    } else if (method == "frame") {
      if (!window_ || !IsWindowVisible(window_)) { result->Success(Value(false)); return; }
      const auto& args = std::get<Map>(*call.arguments());
      const int width = Integer(args, "width"), height = Integer(args, "height");
      const auto& rgba = std::get<std::vector<uint8_t>>(args.at(Value("rgba")));
      if (width < 1 || height < 1 || width > kMaximumWidth || height > kMaximumHeight ||
          rgba.size() != static_cast<size_t>(width) * height * 4)
        throw std::runtime_error("Invalid overlay frame");
      RECT bounds{}; GetWindowRect(window_, &bounds);
      if (bounds.right - bounds.left != width || bounds.bottom - bounds.top != height) {
        result->Success(Value(false)); return;
      }
      BITMAPINFO info{};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
      info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
      info.bmiHeader.biCompression = BI_RGB;
      void* pixels = nullptr;
      HBITMAP bitmap = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
      if (!bitmap) throw std::runtime_error("Overlay bitmap creation failed");
      auto* bgra = static_cast<uint8_t*>(pixels);
      // Flutter rawRgba is premultiplied; Win32 AC_SRC_ALPHA expects premultiplied BGRA.
      for (size_t i = 0; i < rgba.size(); i += 4) {
        bgra[i] = rgba[i + 2]; bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i]; bgra[i + 3] = rgba[i + 3];
      }
      HDC dc = CreateCompatibleDC(nullptr);
      if (!dc) { DeleteObject(bitmap); throw std::runtime_error("Overlay DC creation failed"); }
      HGDIOBJ previous = SelectObject(dc, bitmap);
      POINT origin{}, destination{bounds.left, bounds.top}; SIZE size{width, height};
      BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
      const bool painted = UpdateLayeredWindow(window_, nullptr, &destination, &size,
          dc, &origin, 0, &blend, ULW_ALPHA) != 0;
      SelectObject(dc, previous); DeleteDC(dc); DeleteObject(bitmap);
      if (!painted) throw std::runtime_error("Overlay presentation failed");
      ++rendered_frames_;
      result->Success(Value(true));
#ifndef NDEBUG
    } else if (method == "debugMove") {
      EnsureWindow();
      const auto& args = std::get<Map>(*call.arguments());
      const int width = Integer(args, "width"), height = Integer(args, "height");
      if (width < 280 || width > kMaximumWidth || height < 80 || height > kMaximumHeight)
        throw std::runtime_error("Invalid test bounds");
      int x = Integer(args, "x"), y = Integer(args, "y");
      if (const auto id = args.find(Value("displayId")); id != args.end()) {
        MONITORINFO info{sizeof(MONITORINFO)};
        if (!GetMonitorInfo(Monitor(id->second), &info)) throw std::runtime_error("Invalid test monitor");
        x += info.rcMonitor.left; y += info.rcMonitor.top;
      }
      SetWindowPos(window_, HWND_TOPMOST, x, y, width, height, SWP_NOACTIVATE);
      result->Success(Value(Snapshot()));
    } else if (method == "debugHotkey") {
      SendMessage(window_, WM_HOTKEY, kHotkey, 0);
      result->Success(Value(Snapshot()));
    } else if (method == "debugClose") {
      SendMessage(window_, WM_CLOSE, 0, 0);
      result->Success(Value(Snapshot()));
    } else if (method == "debugHitTest") {
      RECT r{}; GetWindowRect(window_, &r);
      int x = (r.right - r.left) / 2, y = MulDiv(18, GetDpiForWindow(window_), 96);
      if (call.arguments() && std::holds_alternative<Map>(*call.arguments())) {
        const auto& args = std::get<Map>(*call.arguments());
        x = Integer(args, "x"); y = Integer(args, "y");
      }
      result->Success(Value(static_cast<int>(SendMessage(window_, WM_NCHITTEST, 0,
          MAKELPARAM(r.left + x, r.top + y)))));
    } else if (method == "debugScreenshot") {
      // A test-only desktop sample. Call only over a non-sensitive owned fixture.
      RECT r{}; GetWindowRect(window_, &r);
      const int width = r.right - r.left, height = r.bottom - r.top;
      if (!window_ || !IsWindowVisible(window_) || width < 1 || height < 1 ||
          width > kMaximumWidth || height > kMaximumHeight)
        throw std::runtime_error("No test overlay");
      if (!SetWindowDisplayAffinity(window_, WDA_NONE))
        throw std::runtime_error("Cannot sample test overlay");
      DwmFlush();
      HDC desktop = GetDC(nullptr), dc = CreateCompatibleDC(desktop);
      BITMAPINFO info{};
      info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
      info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32;
      info.bmiHeader.biCompression = BI_RGB;
      void* pixels = nullptr;
      HBITMAP bitmap = CreateDIBSection(desktop, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
      bool copied = false;
      std::vector<uint8_t> rgba;
      if (dc && bitmap) {
        const auto previous = SelectObject(dc, bitmap);
        copied = BitBlt(dc, 0, 0, width, height, desktop, r.left, r.top, SRCCOPY | CAPTUREBLT) != 0;
        if (copied) {
          const auto* bgra = static_cast<const uint8_t*>(pixels);
          rgba.resize(static_cast<size_t>(width) * height * 4);
          for (size_t i = 0; i < rgba.size(); i += 4) {
            rgba[i] = bgra[i + 2]; rgba[i + 1] = bgra[i + 1];
            rgba[i + 2] = bgra[i]; rgba[i + 3] = 255;
          }
        }
        SelectObject(dc, previous);
      }
      if (bitmap) DeleteObject(bitmap);
      if (dc) DeleteDC(dc);
      if (desktop) ReleaseDC(nullptr, desktop);
      const bool excluded = SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE) != 0;
      if (!copied || !excluded) throw std::runtime_error("Cannot restore test overlay exclusion");
      result->Success(Value(Map{{Value("width"), Value(width)}, {Value("height"), Value(height)},
          {Value("rgba"), Value(rgba)}}));
#endif
    } else {
      result->NotImplemented();
    }
  } catch (...) {
    result->Error("overlay", "悬浮字幕操作失败，请重试或恢复字幕位置");
  }
}

LRESULT CALLBACK SubtitleOverlay::WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<SubtitleOverlay*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<SubtitleOverlay*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  const int dpi = static_cast<int>(GetDpiForWindow(hwnd));
  switch (message) {
    case WM_NCCALCSIZE: return 0;
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_ERASEBKGND: return 1;
    case WM_NCHITTEST: {
      if (self->locked_) return HTTRANSPARENT;
      RECT r{}; GetWindowRect(hwnd, &r);
      const int x = GET_X_LPARAM(lparam) - r.left, y = GET_Y_LPARAM(lparam) - r.top;
      const int edge = MulDiv(8, dpi, 96), width = r.right - r.left, height = r.bottom - r.top;
      if (y < edge) return x < edge ? HTTOPLEFT : x >= width - edge ? HTTOPRIGHT : HTTOP;
      if (y >= height - edge) return x < edge ? HTBOTTOMLEFT : x >= width - edge ? HTBOTTOMRIGHT : HTBOTTOM;
      if (x < edge) return HTLEFT;
      if (x >= width - edge) return HTRIGHT;
      if (x >= width - MulDiv(38, dpi, 96) && y < MulDiv(34, dpi, 96)) return HTCLIENT;
      return HTCAPTION;
    }
    case WM_LBUTTONUP: {
      RECT r{}; GetClientRect(hwnd, &r);
      if (GET_X_LPARAM(lparam) >= r.right - MulDiv(38, dpi, 96) && GET_Y_LPARAM(lparam) < MulDiv(34, dpi, 96))
        SendMessage(hwnd, WM_CLOSE, 0, 0);
      return 0;
    }
    case WM_NCLBUTTONDBLCLK: return 0;
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE); self->Lock(false);
      if (self->hotkey_) { UnregisterHotKey(hwnd, kHotkey); self->hotkey_ = false; }
      self->Notify(); return 0;
    case WM_HOTKEY:
      if (wparam == kHotkey) { self->Lock(false); self->Notify(); }
      return 0;
    case WM_GETMINMAXINFO: {
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize = {MulDiv(280, dpi, 96), MulDiv(120, dpi, 96)};
      limits->ptMaxTrackSize = {kMaximumWidth, kMaximumHeight}; return 0;
    }
    case WM_DPICHANGED: {
      const auto& r = *reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, HWND_TOPMOST, r.left, r.top,
          std::min(static_cast<int>(r.right - r.left), kMaximumWidth),
          std::min(static_cast<int>(r.bottom - r.top), kMaximumHeight), SWP_NOACTIVATE);
      SetTimer(hwnd, 1, 60, nullptr); return 0;
    }
    case WM_SIZE: SetTimer(hwnd, 1, 60, nullptr); return 0;
    case WM_TIMER:
      if (wparam == 1) { KillTimer(hwnd, 1); self->Notify(); } return 0;
    case WM_DISPLAYCHANGE:
      try { self->Place(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)); } catch (...) {}
      SetTimer(hwnd, 1, 60, nullptr); return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
