#ifndef ECHOPANE_OCR_SERVICE_H_
#define ECHOPANE_OCR_SERVICE_H_

#include <flutter/encodable_value.h>
#include <memory>
#include <string>
#include <vector>

struct CapturePixels {
  std::vector<uint8_t> bytes;
  int width = 0;
  int height = 0;
};

class OcrService {
 public:
  OcrService();
  ~OcrService();
  void Load(const std::string& directory);
  void Submit(std::shared_ptr<const CapturePixels> pixels);
  void Reset();
  flutter::EncodableMap Snapshot();
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
