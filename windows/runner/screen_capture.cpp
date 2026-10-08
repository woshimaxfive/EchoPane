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
#include <mutex>
#include <limits>
#include <stdexcept>
#include <string>
#include <future>
#include <vector>

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
  SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
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

struct Pixels {
  std::vector<uint8_t> bytes;
  int width = 0;
  int height = 0;
};

struct PixelLease {
  std::shared_ptr<Pixels> pixels;
  FlutterDesktopPixelBuffer buffer{};
};
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
  if (!SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE))
    OutputDebugStringW(L"EchoPane: capture exclusion could not be enabled\n");
}

ScreenCapture::~ScreenCapture() {
  channel_->SetMethodCallHandler(nullptr);
  Stop();
#ifndef NDEBUG
  if (fixture_) DestroyWindow(fixture_);
#endif
}

void ScreenCapture::Stop() {
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
    if (method == "debugCreateFixture") {
      Stop();
      if (fixture_) DestroyWindow(fixture_);
      const auto display = Displays().front();
      fixture_ = CreateWindowExW(0, L"STATIC", L"EchoPane capture fixture", WS_POPUP | WS_VISIBLE,
          display.bounds.left + 60, display.bounds.top + 60, 420, 240,
          nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
      if (!fixture_) throw std::runtime_error("Fixture creation failed");
      SetWindowLongPtr(fixture_, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(+[](
          HWND window, UINT message, WPARAM wparam, LPARAM lparam) -> LRESULT {
        if (message == WM_PAINT) {
          PAINTSTRUCT paint{};
          HDC dc = BeginPaint(window, &paint);
          RECT bounds{}; GetClientRect(window, &bounds);
          HBRUSH brush = CreateSolidBrush(RGB(32, 176, 112));
          FillRect(dc, &bounds, brush); DeleteObject(brush);
          EndPaint(window, &paint); return 0;
        }
        return DefWindowProc(window, message, wparam, lparam);
      }));
      InvalidateRect(fixture_, nullptr, TRUE);
      UpdateWindow(fixture_);
      SetWindowPos(window_, HWND_TOPMOST, display.bounds.left + 60, display.bounds.top + 60,
          MulDiv(900, GetDpiForWindow(window_), 96), MulDiv(660, GetDpiForWindow(window_), 96), SWP_SHOWWINDOW);
      RECT crop{60, 60, 480, 300};
      result->Success(EncodableValue(RegionMap(crop)));
      return;
    }
    if (method == "debugDestroyFixture") {
      if (fixture_) DestroyWindow(fixture_);
      fixture_ = nullptr;
      result->Success();
      return;
    }
    if (method == "debugSampleWindowEdge") {
      if (state_ || !fixture_) throw std::runtime_error("Transparency probe requires idle fixture");
      if (!SetWindowDisplayAffinity(window_, WDA_NONE))
        throw std::runtime_error("Cannot prepare transparency probe");
      DwmFlush();
      RECT rectangle{};
      GetWindowRect(window_, &rectangle);
      HDC dc = GetDC(nullptr);
      COLORREF pixel = GetPixel(dc, rectangle.left + 4, rectangle.top + 4);
      ReleaseDC(nullptr, dc);
      if (!SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE))
        throw std::runtime_error("Cannot restore capture exclusion");
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
          if (!selector) Sleep(20);
        }
        if (!selector) return;
        if (cancel) PostMessage(selector, WM_KEYDOWN, VK_ESCAPE, 0);
        else {
          PostMessage(selector, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(360, 240));
          PostMessage(selector, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(100, 80));
          PostMessage(selector, WM_LBUTTONUP, 0, MAKELPARAM(100, 80));
        }
      });
      RECT rectangle{};
      bool accepted = SelectRegion(display, rectangle);
      input.wait();
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
    DWORD affinity = 0;
    if (!GetWindowDisplayAffinity(window_, &affinity) || affinity != WDA_EXCLUDEFROMCAPTURE)
      throw std::runtime_error("未能排除应用自身窗口，无法开始捕获");
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
