#ifndef ECHOPANE_SUBTITLE_OVERLAY_H_
#define ECHOPANE_SUBTITLE_OVERLAY_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <memory>

class SubtitleOverlay {
 public:
  explicit SubtitleOverlay(flutter::FlutterEngine* engine, HWND main_window, bool spatial = false);
  ~SubtitleOverlay();
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  void Handle(const flutter::MethodCall<Value>& call,
              std::unique_ptr<flutter::MethodResult<Value>> result);
  void EnsureWindow(bool allow_capture);
  void Place(HMONITOR monitor);
  bool Lock(bool locked);
  Map Snapshot() const;
  void Notify(bool dismissed = false);
  static LRESULT CALLBACK WindowProc(HWND, UINT, WPARAM, LPARAM);
  HWND main_window_;
  bool spatial_;
  int HotkeyId() const { return spatial_ ? 0x5E02 : 0x5E01; }
  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  bool locked_ = false;
  bool hotkey_ = false;
  int rendered_frames_ = 0;
};

#endif
