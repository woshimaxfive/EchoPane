#ifndef ECHOPANE_SCREEN_CAPTURE_H_
#define ECHOPANE_SCREEN_CAPTURE_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <memory>
#include "ocr_service.h"

class ScreenCapture {
 public:
  ScreenCapture(flutter::FlutterEngine* engine, HWND window);
  ~ScreenCapture();
  ScreenCapture(const ScreenCapture&) = delete;
  ScreenCapture& operator=(const ScreenCapture&) = delete;

 private:
  struct State;
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Stop();
  HWND window_;
  flutter::TextureRegistrar* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::shared_ptr<State> state_;
  OcrService ocr_;
#ifndef NDEBUG
  HWND fixture_ = nullptr;
  std::shared_ptr<CapturePixels> fixture_pixels_;
#endif
};

#endif
