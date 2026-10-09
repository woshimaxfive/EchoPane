#include "screen_capture.h"
#include <flutter/plugin_registrar_windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <dwmapi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <limits>
#include <stdexcept>
#include <string>
#include <future>
#include <vector>
#ifndef NDEBUG
#include <filesystem>
#include <fstream>
#endif

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Graphics;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace {
struct Display {
  HMONITOR monitor;
  RECT bounds;
  bool primary;
};

std::vector<Display> Displays() {
  std::vector<Display> result;
  EnumDisplayMonitors(nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM parameter) -> BOOL {
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        if (GetMonitorInfo(monitor, &info)) {
          reinterpret_cast<std::vector<Display>*>(parameter)->push_back(
              {monitor, info.rcMonitor, (info.dwFlags & MONITORINFOF_PRIMARY) != 0});
        }
        return TRUE;
      }, reinterpret_cast<LPARAM>(&result));
  return result;
}

int64_t Number(const EncodableMap& map, const char* name) {
  const auto& value = map.at(EncodableValue(name));
  if (const auto* number = std::get_if<int32_t>(&value)) return *number;
  return std::get<int64_t>(value);
}

int Integer(const EncodableMap& map, const char* name) {
  const int64_t value = Number(map, name);
  if (value < std::numeric_limits<int>::min() || value > std::numeric_limits<int>::max())
    throw std::runtime_error("捕获坐标超出有效范围");
  return static_cast<int>(value);
}

EncodableMap RegionMap(const RECT& rectangle) {
  return {{EncodableValue("x"), EncodableValue(static_cast<int>(rectangle.left))},
          {EncodableValue("y"), EncodableValue(static_cast<int>(rectangle.top))},
          {EncodableValue("width"), EncodableValue(static_cast<int>(rectangle.right - rectangle.left))},
          {EncodableValue("height"), EncodableValue(static_cast<int>(rectangle.bottom - rectangle.top))}};
}

struct Selection {
  POINT anchor{};
  POINT cursor{};
  RECT rectangle{};
  bool dragging = false;
  bool accepted = false;
};

LRESULT CALLBACK SelectionProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* selection = reinterpret_cast<Selection*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return TRUE;
  }
  if (!selection) return DefWindowProc(window, message, wparam, lparam);
  auto point = [window, lparam]() {
    RECT bounds{};
    GetClientRect(window, &bounds);
    return POINT{std::clamp(static_cast<LONG>(static_cast<short>(LOWORD(lparam))), 0L, bounds.right),
                 std::clamp(static_cast<LONG>(static_cast<short>(HIWORD(lparam))), 0L, bounds.bottom)};
  };
  switch (message) {
    case WM_LBUTTONDOWN:
      selection->anchor = selection->cursor = point();
      selection->dragging = true;
      SetCapture(window);
      return 0;
    case WM_MOUSEMOVE:
      if (selection->dragging) {
        selection->cursor = point();
        InvalidateRect(window, nullptr, FALSE);
      }
      return 0;
    case WM_LBUTTONUP:
      if (selection->dragging) {
        selection->cursor = point();
        selection->rectangle = {
          std::min(selection->anchor.x, selection->cursor.x),
          std::min(selection->anchor.y, selection->cursor.y),
          std::max(selection->anchor.x, selection->cursor.x),
          std::max(selection->anchor.y, selection->cursor.y)};
        selection->accepted = selection->rectangle.right - selection->rectangle.left >= 8 &&
                              selection->rectangle.bottom - selection->rectangle.top >= 8;
        ReleaseCapture();
        DestroyWindow(window);
      }
      return 0;
    case WM_RBUTTONDOWN:
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) DestroyWindow(window);
      return 0;
    case WM_CAPTURECHANGED:
      selection->dragging = false;
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT bounds{};
      GetClientRect(window, &bounds);
      HBRUSH background = CreateSolidBrush(RGB(12, 20, 26));
      FillRect(dc, &bounds, background);
      DeleteObject(background);
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, RGB(255, 255, 255));
      RECT instructions{24, 24, bounds.right - 24, 60};
      DrawTextW(dc, L"拖动鼠标框选区域 · Esc 或右键取消", -1, &instructions, DT_LEFT | DT_SINGLELINE);
      if (selection->dragging) {
        HPEN border = CreatePen(PS_SOLID, 3, RGB(100, 255, 235));
        auto old_pen = SelectObject(dc, border);
        auto old_brush = SelectObject(dc, GetStockObject(NULL_BRUSH));
        Rectangle(dc, std::min(selection->anchor.x, selection->cursor.x),
            std::min(selection->anchor.y, selection->cursor.y),
            std::max(selection->anchor.x, selection->cursor.x),
            std::max(selection->anchor.y, selection->cursor.y));
        SelectObject(dc, old_brush);
        SelectObject(dc, old_pen);
        DeleteObject(border);
      }
      EndPaint(window, &paint);
      return 0;
    }
  }
  return DefWindowProc(window, message, wparam, lparam);
}

bool SelectRegion(const Display& display, RECT& rectangle) {
  const HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASSW klass{};
  klass.hInstance = instance;
  klass.lpfnWndProc = SelectionProc;
  klass.lpszClassName = L"EchoPaneRegionSelection";
  klass.hCursor = LoadCursor(nullptr, IDC_CROSS);
  if (!RegisterClassW(&klass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    throw std::runtime_error("Could not create region selector");
  Selection selection;
  HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TOOLWINDOW,
      klass.lpszClassName, L"EchoPane Region", WS_POPUP,
      display.bounds.left, display.bounds.top,
      display.bounds.right - display.bounds.left, display.bounds.bottom - display.bounds.top,
      nullptr, nullptr, instance, &selection);
  if (!window) throw std::runtime_error("Could not open region selector");
  SetLayeredWindowAttributes(window, 0, 110, LWA_ALPHA);
  // Capture is stopped during selection; allow remote users to see the drag box.
  SetWindowDisplayAffinity(window, WDA_NONE);
  ShowWindow(window, SW_SHOW);
  SetForegroundWindow(window);
  SetFocus(window);
  MSG message{};
  while (IsWindow(window)) {
    const BOOL received = GetMessage(&message, nullptr, 0, 0);
    if (received <= 0) {
      if (IsWindow(window)) DestroyWindow(window);
      if (received == 0) PostQuitMessage(static_cast<int>(message.wParam));
      break;
    }
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  rectangle = selection.rectangle;
  return selection.accepted;
}

using Pixels = CapturePixels;

struct PixelLease {
  std::shared_ptr<Pixels> pixels;
  FlutterDesktopPixelBuffer buffer{};
};

// Remote-visible layered translations must not become OCR input. This scoped
// GDI sample hides only this process's visible overlays and restores them even
// when capture fails. WGC remains the regular capture/preview path.
std::shared_ptr<Pixels> SampleBehindOverlays(const RECT& bounds) {
  struct OwnedOverlays {
    const RECT& bounds;
    std::vector<HWND> windows;
  } owned{bounds, {}};
  // Another running instance may have the same classes. Enumerate by owner
  // rather than accepting the first window with a matching class name.
  EnumWindows(+[](HWND window, LPARAM parameter) -> BOOL {
    auto& owned = *reinterpret_cast<OwnedOverlays*>(parameter);
    DWORD process = 0, affinity = 0;
    RECT window_bounds{}, intersection{};
    GetWindowThreadProcessId(window, &process);
    if (process != GetCurrentProcessId() || !IsWindowVisible(window)) return TRUE;
    wchar_t name[64]{};
    GetClassNameW(window, name, 64);
    if (std::wcscmp(name, L"EchoPaneScreenOverlay") != 0 &&
        std::wcscmp(name, L"EchoPaneSubtitleOverlay") != 0) return TRUE;
    if (GetWindowRect(window, &window_bounds) && IntersectRect(&intersection, &window_bounds, &owned.bounds) &&
        GetWindowDisplayAffinity(window, &affinity) && affinity == WDA_NONE)
      owned.windows.push_back(window);
    return TRUE;
  }, reinterpret_cast<LPARAM>(&owned));
  const auto& overlays = owned.windows;
  if (overlays.empty()) return nullptr;
  const int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
  if (width < 1 || height < 1 || width > 8192 || height > 8192 ||
      static_cast<int64_t>(width) * height > 33554432)
    throw std::runtime_error("远程兼容取样范围过大，请缩小识别区域");
  auto pixels = std::make_shared<Pixels>();
  pixels->width = width; pixels->height = height;
  pixels->bytes.resize(static_cast<size_t>(width) * height * 4);
  struct SampleResources {
    HDC desktop = nullptr, dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    std::vector<HWND> hidden;
    ~SampleResources() {
      for (const auto window : hidden) if (IsWindow(window))
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
      if (previous) SelectObject(dc, previous);
      if (bitmap) DeleteObject(bitmap);
      if (dc) DeleteDC(dc);
      if (desktop) ReleaseDC(nullptr, desktop);
    }
  } sample;
  sample.desktop = GetDC(nullptr);
  if (!sample.desktop) throw std::runtime_error("无法读取桌面画面");
  sample.dc = CreateCompatibleDC(sample.desktop);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width; info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
  void* data = nullptr;
  sample.bitmap = CreateDIBSection(sample.desktop, &info, DIB_RGB_COLORS, &data, nullptr, 0);
  if (!sample.dc || !sample.bitmap) throw std::runtime_error("无法创建远程兼容取样");
  sample.previous = SelectObject(sample.dc, sample.bitmap);
  sample.hidden = overlays;
  for (const auto window : overlays) ShowWindow(window, SW_HIDE);
  if (FAILED(DwmFlush()) || !BitBlt(sample.dc, 0, 0, width, height, sample.desktop,
      bounds.left, bounds.top, SRCCOPY | CAPTUREBLT))
    throw std::runtime_error("无法获取译文下方画面，请关闭远程兼容后重试");
  std::memcpy(pixels->bytes.data(), data, pixels->bytes.size());
  for (const auto window : sample.hidden)
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  sample.hidden.clear();
  for (size_t i = 0; i < pixels->bytes.size(); i += 4) {
    std::swap(pixels->bytes[i], pixels->bytes[i + 2]); pixels->bytes[i + 3] = 255;
  }
  return pixels;
}
}  // namespace

struct ScreenCapture::State {
  std::atomic<bool> running{false};
  std::mutex processing;
  std::mutex pixels_mutex;
  std::shared_ptr<Pixels> latest;
  std::string error;
  uint64_t frames = 0;
  std::chrono::steady_clock::time_point last_frame{};
  RECT crop{};
  RECT display_bounds{};
  int remote_samples = 0, remote_sample_ms = 0;
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  winrt::com_ptr<ID3D11Texture2D> staging;
  Direct3D11CaptureFramePool pool{nullptr};
  GraphicsCaptureSession session{nullptr};
  winrt::event_token arrival{};
  winrt::event_token closed{};
  GraphicsCaptureItem item{nullptr};
  flutter::TextureRegistrar* registrar = nullptr;
  int64_t texture_id = -1;

  void Frame(const Direct3D11CaptureFramePool& sender) {
    std::lock_guard lock(processing);
    if (!running) return;
    try {
      auto frame = sender.TryGetNextFrame();
      if (!frame) return;
      auto now = std::chrono::steady_clock::now();
      if (now - last_frame < std::chrono::milliseconds(100)) return;
      last_frame = now;
      auto access = frame.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
      winrt::com_ptr<ID3D11Texture2D> source;
      winrt::check_hresult(access->GetInterface(__uuidof(ID3D11Texture2D), source.put_void()));
      D3D11_TEXTURE2D_DESC source_desc{};
      source->GetDesc(&source_desc);
      const auto content = frame.ContentSize();
      if (crop.right > content.Width || crop.bottom > content.Height ||
          crop.right > static_cast<LONG>(source_desc.Width) || crop.bottom > static_cast<LONG>(source_desc.Height))
        throw std::runtime_error("显示器尺寸已改变，请重新选择捕获范围");
      D3D11_BOX box{static_cast<UINT>(crop.left), static_cast<UINT>(crop.top), 0,
                    static_cast<UINT>(crop.right), static_cast<UINT>(crop.bottom), 1};
      context->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, source.get(), 0, &box);
      D3D11_MAPPED_SUBRESOURCE mapped{};
      winrt::check_hresult(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped));
      auto pixels = std::make_shared<Pixels>();
      pixels->width = crop.right - crop.left;
      pixels->height = crop.bottom - crop.top;
      try {
        pixels->bytes.resize(static_cast<size_t>(pixels->width) * pixels->height * 4);
        for (int y = 0; y < pixels->height; ++y) {
          const auto* input = static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch;
          auto* output = pixels->bytes.data() + static_cast<size_t>(y) * pixels->width * 4;
          for (int x = 0; x < pixels->width; ++x) {
            output[x * 4] = input[x * 4 + 2];
            output[x * 4 + 1] = input[x * 4 + 1];
            output[x * 4 + 2] = input[x * 4];
            output[x * 4 + 3] = 255;
          }
        }
      } catch (...) {
        context->Unmap(staging.get(), 0);
        throw;
      }
      context->Unmap(staging.get(), 0);
      {
        std::lock_guard pixels_lock(pixels_mutex);
        latest = std::move(pixels);
        ++frames;
      }
      if (running) registrar->MarkTextureFrameAvailable(texture_id);
    } catch (const winrt::hresult_error& exception) {
      std::lock_guard pixels_lock(pixels_mutex);
      error = winrt::to_string(exception.message());
      running = false;
    } catch (const std::exception& exception) {
      std::lock_guard pixels_lock(pixels_mutex);
      error = exception.what();
      running = false;
    }
  }
};

ScreenCapture::ScreenCapture(flutter::FlutterEngine* engine, HWND window)
    : window_(window), registrar_(flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(engine->GetRegistrarForPlugin("EchoPaneCapture"))
          ->texture_registrar()) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), "echopane/capture", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Handle(call, std::move(result));
  });
  // Keep controls visible to remote desktops and recorders.
  SetWindowDisplayAffinity(window_, WDA_NONE);
}

ScreenCapture::~ScreenCapture() {
  channel_->SetMethodCallHandler(nullptr);
  Stop();
#ifndef NDEBUG
  if (fixture_) DestroyWindow(fixture_);
#endif
}

void ScreenCapture::Stop() {
  ocr_.Reset();
  if (state_) {
    state_->running = false;
    { std::lock_guard lock(state_->processing); }
    if (state_->pool) {
      if (state_->arrival.value) state_->pool.FrameArrived(state_->arrival);
      state_->pool.Close();
      state_->pool = nullptr;
    }
    if (state_->item && state_->closed.value) state_->item.Closed(state_->closed);
    if (state_->session) {
      state_->session.Close();
      state_->session = nullptr;
    }
  }
  if (texture_id_ >= 0) {
    auto texture = std::shared_ptr<flutter::TextureVariant>(std::move(texture_));
    registrar_->UnregisterTexture(texture_id_, [texture]() {});
  }
  texture_id_ = -1;
  texture_.reset();
  state_.reset();
}

void ScreenCapture::Handle(const flutter::MethodCall<EncodableValue>& call,
                          std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  try {
    const auto method = call.method_name();
    if (method == "ocrLoad") {
      const auto& arguments = std::get<EncodableMap>(*call.arguments());
      ocr_.Load(std::get<std::string>(arguments.at(EncodableValue("directory"))));
      result->Success();
      return;
    }
    if (method == "ocrSnapshot") {
      if (state_ && state_->running) {
        std::shared_ptr<Pixels> pixels;
        const auto started = std::chrono::steady_clock::now();
        const RECT bounds{state_->display_bounds.left + state_->crop.left, state_->display_bounds.top + state_->crop.top,
            state_->display_bounds.left + state_->crop.right, state_->display_bounds.top + state_->crop.bottom};
        pixels = SampleBehindOverlays(bounds);
        if (pixels) {
          ++state_->remote_samples;
          state_->remote_sample_ms = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - started).count());
        } else { std::lock_guard lock(state_->pixels_mutex); pixels = state_->latest; }
        if (pixels) ocr_.Submit(std::move(pixels));
      }
      result->Success(EncodableValue(ocr_.Snapshot()));
      return;
    }
    if (method == "displays") {
      EncodableList values;
      const auto displays = Displays();
      for (size_t index = 0; index < displays.size(); ++index) {
        const auto& display = displays[index];
        values.emplace_back(EncodableMap{
          {EncodableValue("id"), EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(display.monitor)))},
          {EncodableValue("name"), EncodableValue("显示器 " + std::to_string(index + 1) + (display.primary ? "（主屏）" : ""))},
          {EncodableValue("width"), EncodableValue(static_cast<int>(display.bounds.right - display.bounds.left))},
          {EncodableValue("height"), EncodableValue(static_cast<int>(display.bounds.bottom - display.bounds.top))},
          {EncodableValue("primary"), EncodableValue(display.primary)}});
      }
      result->Success(EncodableValue(values));
      return;
    }
    if (method == "stop") {
      Stop();
      result->Success();
      return;
    }
    if (method == "snapshot") {
      EncodableMap value{{EncodableValue("frames"), EncodableValue(int64_t{0})},
                         {EncodableValue("width"), EncodableValue(0)},
                         {EncodableValue("height"), EncodableValue(0)}};
      if (state_) {
        value[EncodableValue("remoteSamples")] = EncodableValue(state_->remote_samples);
        value[EncodableValue("remoteSampleMs")] = EncodableValue(state_->remote_sample_ms);
        std::lock_guard lock(state_->pixels_mutex);
        value[EncodableValue("frames")] = EncodableValue(static_cast<int64_t>(state_->frames));
        if (state_->latest) {
          value[EncodableValue("width")] = EncodableValue(state_->latest->width);
          value[EncodableValue("height")] = EncodableValue(state_->latest->height);
#ifndef NDEBUG
          const auto& pixels = *state_->latest;
          size_t center = (static_cast<size_t>(pixels.height / 2) * pixels.width + pixels.width / 2) * 4;
          value[EncodableValue("centerPixel")] = EncodableValue(EncodableList{
            EncodableValue(pixels.bytes[center]), EncodableValue(pixels.bytes[center + 1]),
            EncodableValue(pixels.bytes[center + 2])});
#endif
        }
        if (!state_->error.empty()) value[EncodableValue("error")] = EncodableValue(state_->error);
      }
      DWORD affinity = 0;
      GetWindowDisplayAffinity(window_, &affinity);
      value[EncodableValue("excluded")] = EncodableValue(affinity == WDA_EXCLUDEFROMCAPTURE);
      value[EncodableValue("topmost")] = EncodableValue((GetWindowLongPtr(window_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0);
      value[EncodableValue("dpi")] = EncodableValue(static_cast<int>(GetDpiForWindow(window_)));
      result->Success(EncodableValue(value));
      return;
    }
#ifndef NDEBUG
    if (method == "debugCapturedFixture") {
      if (!fixture_ || !state_) throw std::runtime_error("Owned capture fixture required");
      std::lock_guard lock(state_->pixels_mutex);
      if (!state_->latest) throw std::runtime_error("No fixture frame");
      const auto& pixels = *state_->latest;
      result->Success(EncodableValue(EncodableMap{{EncodableValue("width"), EncodableValue(pixels.width)},
          {EncodableValue("height"), EncodableValue(pixels.height)}, {EncodableValue("rgba"), EncodableValue(pixels.bytes)}}));
      return;
    }
    auto read_fixture = [&call]() {
      const auto& options = std::get<EncodableMap>(*call.arguments());
      auto pixels = std::make_shared<CapturePixels>();
      pixels->width = Integer(options, "width");
      pixels->height = Integer(options, "height");
      if (pixels->width < 8 || pixels->height < 8 || pixels->width > 1920 || pixels->height > 1080)
        throw std::runtime_error("Invalid test image dimensions");
      const auto& path = std::get<std::string>(options.at(EncodableValue("path")));
      const auto utf8_path = std::u8string(reinterpret_cast<const char8_t*>(path.data()), path.size());
      std::ifstream input(std::filesystem::path(utf8_path), std::ios::binary);
      pixels->bytes.resize(static_cast<size_t>(pixels->width) * pixels->height * 4);
      if (!input.read(reinterpret_cast<char*>(pixels->bytes.data()), pixels->bytes.size()))
        throw std::runtime_error("Could not read test image");
      for (size_t index = 0; index < pixels->bytes.size(); index += 4)
        std::swap(pixels->bytes[index], pixels->bytes[index + 2]); // RGBA fixture to GDI BGRA.
      return pixels;
    };
    if (method == "debugUpdateFixture") {
      if (!fixture_) throw std::runtime_error("Test window is absent");
      fixture_pixels_ = read_fixture();
      SetWindowLongPtr(fixture_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(fixture_pixels_.get()));
      InvalidateRect(fixture_, nullptr, FALSE);
      UpdateWindow(fixture_);
      DwmFlush();
      result->Success();
      return;
    }
    if (method == "debugCreateFixture") {
      Stop();
      if (fixture_) DestroyWindow(fixture_);
      fixture_pixels_.reset();
      if (call.arguments() && !std::holds_alternative<std::monostate>(*call.arguments()))
        fixture_pixels_ = read_fixture();
      const int width = fixture_pixels_ ? fixture_pixels_->width : 420;
      const int height = fixture_pixels_ ? fixture_pixels_->height : 240;
      const auto display = Displays().front();
      fixture_ = CreateWindowExW(0, L"STATIC", L"EchoPane capture fixture", WS_POPUP | WS_VISIBLE,
          display.bounds.left + 60, display.bounds.top + 60, width, height,
          nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
      if (!fixture_) throw std::runtime_error("Fixture creation failed");
      SetWindowLongPtr(fixture_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(+[](
          HWND window, UINT message, WPARAM wparam, LPARAM lparam) -> LRESULT {
        if (message == WM_PAINT) {
          PAINTSTRUCT paint{};
          HDC dc = BeginPaint(window, &paint);
          RECT bounds{}; GetClientRect(window, &bounds);
          const auto* pixels = reinterpret_cast<CapturePixels*>(GetWindowLongPtr(window, GWLP_USERDATA));
          if (pixels) {
            BITMAPINFO bitmap{};
            bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            bitmap.bmiHeader.biWidth = pixels->width;
            bitmap.bmiHeader.biHeight = -pixels->height;
            bitmap.bmiHeader.biPlanes = 1;
            bitmap.bmiHeader.biBitCount = 32;
            bitmap.bmiHeader.biCompression = BI_RGB;
            SetDIBitsToDevice(dc, 0, 0, pixels->width, pixels->height, 0, 0, 0,
                pixels->height, pixels->bytes.data(), &bitmap, DIB_RGB_COLORS);
          } else {
            HBRUSH brush = CreateSolidBrush(RGB(32, 176, 112));
            FillRect(dc, &bounds, brush); DeleteObject(brush);
          }
          EndPaint(window, &paint); return 0;
        }
        return DefWindowProc(window, message, wparam, lparam);
      }));
      SetWindowLongPtr(fixture_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(fixture_pixels_.get()));
      InvalidateRect(fixture_, nullptr, TRUE);
      UpdateWindow(fixture_);
      // Text fixtures must not be obscured by the now-capturable controls.
      const int main_y = display.bounds.top + 60 + (fixture_pixels_ ? height + 24 : 0);
      SetWindowPos(window_, HWND_TOPMOST, display.bounds.left + 60, main_y,
          MulDiv(900, GetDpiForWindow(window_), 96), MulDiv(660, GetDpiForWindow(window_), 96), SWP_SHOWWINDOW);
      RECT crop{60, 60, 60 + width, 60 + height};
      result->Success(EncodableValue(RegionMap(crop)));
      return;
    }
    if (method == "debugDestroyFixture") {
      if (fixture_) DestroyWindow(fixture_);
      fixture_ = nullptr;
      fixture_pixels_.reset();
      result->Success();
      return;
    }
    if (method == "debugSampleWindowEdge") {
      if (state_ || !fixture_) throw std::runtime_error("Transparency probe requires idle fixture");
      DwmFlush();
      RECT rectangle{};
      GetWindowRect(window_, &rectangle);
      HDC dc = GetDC(nullptr);
      COLORREF pixel = GetPixel(dc, rectangle.left + 4, rectangle.top + 4);
      ReleaseDC(nullptr, dc);
      result->Success(EncodableValue(EncodableList{
        EncodableValue(GetRValue(pixel)), EncodableValue(GetGValue(pixel)), EncodableValue(GetBValue(pixel))}));
      return;
    }
    if (method == "debugSelectRegion") {
      const auto& options = std::get<EncodableMap>(*call.arguments());
      const bool cancel = std::get<bool>(options.at(EncodableValue("cancel")));
      const auto display = Displays().front();
      auto input = std::async(std::launch::async, [cancel]() {
        HWND selector = nullptr;
        for (int retry = 0; retry < 100 && !selector; ++retry) {
          selector = FindWindowW(L"EchoPaneRegionSelection", nullptr);
          if (selector && !IsWindowVisible(selector)) selector = nullptr;
          if (!selector) Sleep(20);
        }
        if (!selector) return DWORD{0xffffffff};
        DWORD affinity = 0xffffffff;
        GetWindowDisplayAffinity(selector, &affinity);
        if (cancel) PostMessage(selector, WM_KEYDOWN, VK_ESCAPE, 0);
        else {
          PostMessage(selector, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(360, 240));
          PostMessage(selector, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(100, 80));
          PostMessage(selector, WM_LBUTTONUP, 0, MAKELPARAM(100, 80));
        }
        return affinity;
      });
      RECT rectangle{};
      bool accepted = SelectRegion(display, rectangle);
      if (input.get() != WDA_NONE)
        throw std::runtime_error("Region selector is not capturable");
      if (accepted) result->Success(EncodableValue(RegionMap(rectangle)));
      else result->Success();
      return;
    }
#endif
    if (method != "start" && method != "selectRegion") {
      result->NotImplemented();
      return;
    }
    const auto& arguments = std::get<EncodableMap>(*call.arguments());
    const auto displays = Displays();
    const int64_t display_id = Number(arguments, "displayId");
    const auto chosen = std::find_if(displays.begin(), displays.end(), [display_id](const Display& value) {
      return static_cast<int64_t>(reinterpret_cast<intptr_t>(value.monitor)) == display_id;
    });
    if (chosen == displays.end())
      throw std::runtime_error("显示器已断开，请重新启动程序选择显示器");
    const auto& display = *chosen;
    RECT crop{0, 0, display.bounds.right - display.bounds.left, display.bounds.bottom - display.bounds.top};
    if (method == "selectRegion") {
      Stop();
      const bool accepted = SelectRegion(display, crop);
      SetForegroundWindow(window_);
      if (accepted) result->Success(EncodableValue(RegionMap(crop)));
      else result->Success();
      return;
    }
    Stop();
    if (!GraphicsCaptureSession::IsSupported())
      throw std::runtime_error("当前系统不支持屏幕捕获");
    auto region = arguments.find(EncodableValue("region"));
    if (region != arguments.end()) {
      const auto& values = std::get<EncodableMap>(region->second);
      const int x = Integer(values, "x"), y = Integer(values, "y");
      const int width = Integer(values, "width"), height = Integer(values, "height");
      const int display_width = display.bounds.right - display.bounds.left;
      const int display_height = display.bounds.bottom - display.bounds.top;
      if (x < 0 || y < 0 || width < 8 || height < 8 ||
          x >= display_width || y >= display_height ||
          width > display_width - x || height > display_height - y)
        throw std::runtime_error("捕获范围无效，请重新框选");
      crop = {x, y, x + width, y + height};
    }
    auto state = std::make_shared<State>();
    state_ = state;
    state->crop = crop;
    state->display_bounds = display.bounds;
    state->registrar = registrar_;
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    D3D_FEATURE_LEVEL level{};
    HRESULT created = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
        nullptr, 0, D3D11_SDK_VERSION, state->device.put(), &level, state->context.put());
    if (FAILED(created)) created = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
        flags, nullptr, 0, D3D11_SDK_VERSION, state->device.put(), &level, state->context.put());
    winrt::check_hresult(created);
    auto dxgi = state->device.as<IDXGIDevice>();
    winrt::com_ptr<IInspectable> inspectable;
    winrt::check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
    auto device = inspectable.as<IDirect3DDevice>();
    auto factory = winrt::get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    winrt::check_hresult(factory->CreateForMonitor(display.monitor,
        winrt::guid_of<GraphicsCaptureItem>(), winrt::put_abi(state->item)));
    state->pool = Direct3D11CaptureFramePool::CreateFreeThreaded(device,
        DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, state->item.Size());
    D3D11_TEXTURE2D_DESC description{};
    description.Width = crop.right - crop.left;
    description.Height = crop.bottom - crop.top;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_STAGING;
    description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    winrt::check_hresult(state->device->CreateTexture2D(&description, nullptr, state->staging.put()));
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [weak = std::weak_ptr<State>(state)](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
          auto locked = weak.lock();
          if (!locked) return nullptr;
          std::shared_ptr<Pixels> pixels;
          { std::lock_guard lock(locked->pixels_mutex); pixels = locked->latest; }
          if (!pixels) return nullptr;
          auto* lease = new PixelLease;
          lease->pixels = std::move(pixels);
          lease->buffer.buffer = lease->pixels->bytes.data();
          lease->buffer.width = lease->pixels->width;
          lease->buffer.height = lease->pixels->height;
          lease->buffer.release_context = lease;
          lease->buffer.release_callback = [](void* context) { delete static_cast<PixelLease*>(context); };
          return &lease->buffer;
        }));
    texture_id_ = registrar_->RegisterTexture(texture_.get());
    if (texture_id_ < 0) throw std::runtime_error("无法创建屏幕预览纹理");
    state->texture_id = texture_id_;
    state->running = true;
    state->arrival = state->pool.FrameArrived([weak = std::weak_ptr<State>(state)](auto&& sender, auto&&) {
      if (auto locked = weak.lock()) locked->Frame(sender);
    });
    state->closed = state->item.Closed([weak = std::weak_ptr<State>(state)](auto&&, auto&&) {
      if (auto locked = weak.lock()) {
        std::lock_guard lock(locked->pixels_mutex);
        locked->error = "显示器捕获已结束，请重新开始";
        locked->running = false;
      }
    });
    state->session = state->pool.CreateCaptureSession(state->item);
    state->session.IsCursorCaptureEnabled(false);
    if (auto settings = state->session.try_as<IGraphicsCaptureSession5>())
      settings.MinUpdateInterval(std::chrono::milliseconds(100));
    state->session.StartCapture();
    result->Success(EncodableValue(texture_id_));
  } catch (const winrt::hresult_error& exception) {
    Stop();
    result->Error("capture_unavailable", winrt::to_string(exception.message()));
  } catch (const std::exception& exception) {
    Stop();
    result->Error("capture_failed", exception.what());
  }
}
