#pragma once
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include "audio_engine.h"

class AudioService {
 public:
  explicit AudioService(flutter::FlutterEngine* engine);
  ~AudioService();
 private:
  AudioEngine audio_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
