#include "ocr_service.h"
#include "OcrLite.h"
#include <opencv2/imgproc.hpp>
#include <opencv2/photo.hpp>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <numeric>
#include <thread>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
// Repair only the OCR text's neighbourhood, using the already bundled OpenCV.
// Missing or oversized patches retain the existing sampled-colour fallback.
EncodableValue BackgroundPatch(const cv::Mat& bgr, const cv::Rect& box,
    const cv::Scalar& background, const std::vector<cv::Rect>& boxes) {
  const auto image = cv::Rect(0, 0, bgr.cols, bgr.rows);
  const int padding = std::clamp(box.height / 7, 3, 8) + 2;
  const auto painted = cv::Rect(box.x - padding, box.y - padding,
      box.width + padding * 2, box.height + padding * 2) & image;
  const int margin = std::clamp(box.height / 3, 6, 16);
  const auto work = cv::Rect(painted.x - margin, painted.y - margin,
      painted.width + margin * 2, painted.height + margin * 2) & image;
  if (work.area() > 500000) return EncodableValue();
  try {
    cv::Mat mask(work.size(), CV_8UC1, cv::Scalar(0));
    const auto local = cv::Rect(box.x - work.x, box.y - work.y, box.width, box.height);
    for (int y = 0; y < local.height; ++y) {
      const auto* pixels = bgr.ptr<cv::Vec3b>(box.y + y) + box.x;
      auto* row = mask.ptr<uint8_t>(local.y + y) + local.x;
      for (int x = 0; x < local.width; ++x) {
        double distance = 0;
        for (int c = 0; c < 3; ++c) {
          const double difference = pixels[x][c] - background[c];
          distance += difference * difference;
        }
        if (distance > 3600) row[x] = 255;
      }
    }
    if (cv::countNonZero(mask(local)) > box.area() * 0.65)
      cv::rectangle(mask, cv::Rect(painted.x - work.x, painted.y - work.y,
          painted.width, painted.height), cv::Scalar(255), -1);
    const int stroke = padding * 2 + 1;
    cv::dilate(mask, mask, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(stroke, stroke)));
    // Adjacent source text must never be used to rebuild another line's background.
    for (const auto& other : boxes) {
      if (other == box) continue;
      const auto covered = cv::Rect(other.x - padding, other.y - padding,
          other.width + padding * 2, other.height + padding * 2) & work;
      if (!covered.empty()) cv::rectangle(mask,
          cv::Rect(covered.x - work.x, covered.y - work.y, covered.width, covered.height), cv::Scalar(255), -1);
    }
    cv::Mat repaired, rgba;
    cv::inpaint(bgr(work), mask, repaired, 3, cv::INPAINT_TELEA);
    cv::cvtColor(repaired(cv::Rect(painted.x - work.x, painted.y - work.y,
        painted.width, painted.height)), rgba, cv::COLOR_BGR2RGBA);
    std::vector<uint8_t> bytes(rgba.datastart, rgba.dataend);
    return EncodableValue(EncodableMap{{EncodableValue("x"), EncodableValue(painted.x)},
        {EncodableValue("y"), EncodableValue(painted.y)},
        {EncodableValue("width"), EncodableValue(painted.width)},
        {EncodableValue("height"), EncodableValue(painted.height)},
        {EncodableValue("rgba"), EncodableValue(bytes)}});
  } catch (const cv::Exception&) { return EncodableValue(); }
}
}

struct OcrService::Impl {
  std::mutex mutex;
  std::condition_variable changed;
  bool exiting = false;
  bool loading = false;
  bool ready = false;
  bool busy = false;
  std::string directory;
  std::string error;
  uint64_t generation = 0;
  uint64_t revision = 0;
  uint64_t hash = 0;
  uint64_t recognized = 0;
  uint64_t skipped = 0;
  int duration = 0;
  int width = 0, height = 0;
#ifndef NDEBUG
  int detected_boxes = 0, accepted_boxes = 0;
#endif
  EncodableList lines;
  std::shared_ptr<const CapturePixels> pending;
  std::thread worker;

  Impl() : worker([this] { Run(); }) {}
  ~Impl() {
    { std::lock_guard lock(mutex); exiting = true; pending.reset(); }
    changed.notify_one();
    worker.join();
  }

  void Run() {
    std::unique_ptr<OcrLite> engine;
    while (true) {
      std::unique_lock lock(mutex);
      changed.wait(lock, [this] { return exiting || loading || pending; });
      if (exiting) break;
      const auto token = generation;
      if (loading) {
        const auto path = directory;
        loading = false;
        busy = true;
        lock.unlock();
        try {
          auto next = std::make_unique<OcrLite>();
          next->setNumThread(2);
          next->initLogger(false, false, false);
          next->initModels(path + "/det.onnx", "", path + "/rec.onnx", path + "/keys.txt");
          lock.lock();
          engine = std::move(next);
          ready = true;
          error.clear();
        } catch (const std::exception&) {
          lock.lock();
          engine.reset();
          ready = false;
          error = "模型加载失败，请重新下载模型后重试";
        }
        busy = false;
        continue;
      }
      auto pixels = std::move(pending);
      if (!engine || !ready || !pixels) continue;
      busy = true;
      lock.unlock();
      const auto started = std::chrono::steady_clock::now();
      try {
        uint64_t image_hash = 14695981039346656037ULL;
        for (auto byte : pixels->bytes) image_hash = (image_hash ^ byte) * 1099511628211ULL;
        image_hash ^= static_cast<uint64_t>(pixels->width) << 32 | pixels->height;
        lock.lock();
        if (token != generation || image_hash == hash) {
          if (token == generation) ++skipped;
          busy = false;
          continue;
        }
        lock.unlock();
        cv::Mat rgba(pixels->height, pixels->width, CV_8UC4,
                     const_cast<uint8_t*>(pixels->bytes.data()));
        cv::Mat bgr;
        cv::cvtColor(rgba, bgr, cv::COLOR_RGBA2BGR);
        auto result = engine->detect(bgr, 16, 1280, 0.5f, 0.3f, 1.6f, false, false);
        struct Line { int x, y, width, height; std::string text; float confidence; };
        std::vector<Line> ordered;
        for (const auto& block : result.textBlocks) {
          if (block.text.empty() || block.charScores.empty()) continue;
          const float confidence = std::accumulate(block.charScores.begin(), block.charScores.end(), 0.f)
                                   / static_cast<float>(block.charScores.size());
          if (confidence < 0.5f) continue;
          int left = pixels->width, top = pixels->height, right = 0, bottom = 0;
          for (const auto& point : block.boxPoint) {
            left = std::min(left, point.x); top = std::min(top, point.y);
            right = std::max(right, point.x); bottom = std::max(bottom, point.y);
          }
          ordered.push_back({left, top, right-left, bottom-top, block.text, confidence});
        }
        std::stable_sort(ordered.begin(), ordered.end(), [](const Line& a, const Line& b) {
          return a.y != b.y ? a.y < b.y : a.x < b.x;
        });
        EncodableList output;
        std::vector<cv::Rect> boxes;
        for (const auto& line : ordered)
          boxes.push_back(cv::Rect(line.x, line.y, line.width, line.height) & cv::Rect(0, 0, bgr.cols, bgr.rows));
        for (const auto& line : ordered) {
          const auto box = cv::Rect(line.x, line.y, line.width, line.height) & cv::Rect(0, 0, bgr.cols, bgr.rows);
          if (box.empty()) continue;
          const auto surrounding = cv::Rect(box.x - 4, box.y - 4, box.width + 8, box.height + 8)
              & cv::Rect(0, 0, bgr.cols, bgr.rows);
          cv::Mat mask(surrounding.size(), CV_8UC1, cv::Scalar(255));
          cv::rectangle(mask, cv::Rect(box.x - surrounding.x, box.y - surrounding.y, box.width, box.height), cv::Scalar(0), -1);
          const auto color = cv::countNonZero(mask) ? cv::mean(bgr(surrounding), mask) : cv::mean(bgr(box));
          const int64_t background = 0xff000000LL | (static_cast<int64_t>(color[2]) << 16)
              | (static_cast<int64_t>(color[1]) << 8) | static_cast<int64_t>(color[0]);
          output.emplace_back(EncodableMap{
          {EncodableValue("text"), EncodableValue(line.text)},
          {EncodableValue("confidence"), EncodableValue(static_cast<double>(line.confidence))},
          {EncodableValue("x"), EncodableValue(line.x)}, {EncodableValue("y"), EncodableValue(line.y)},
          {EncodableValue("width"), EncodableValue(line.width)}, {EncodableValue("height"), EncodableValue(line.height)},
          {EncodableValue("background"), EncodableValue(background)},
          {EncodableValue("patch"), BackgroundPatch(bgr, box, color, boxes)}});
        }
        lock.lock();
        if (token == generation) {
#ifndef NDEBUG
          detected_boxes = static_cast<int>(result.textBlocks.size());
          accepted_boxes = static_cast<int>(ordered.size());
#endif
          lines = std::move(output);
          width = pixels->width; height = pixels->height;
          hash = image_hash;
          ++revision;
          ++recognized;
          duration = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now() - started).count());
          error.clear();
        }
      } catch (const std::exception&) {
        if (!lock.owns_lock()) lock.lock();
        if (token == generation) error = "本次文字识别失败，请停止后重新开始";
      }
      busy = false;
    }
  }
};

OcrService::OcrService() : impl_(std::make_unique<Impl>()) {}
OcrService::~OcrService() = default;
void OcrService::Load(const std::string& directory) {
  std::lock_guard lock(impl_->mutex);
  if (impl_->loading) return;
  ++impl_->generation;
  impl_->directory = directory;
  impl_->ready = false;
  impl_->loading = true;
  impl_->pending.reset();
  impl_->hash = 0;
  impl_->lines.clear();
  impl_->width = impl_->height = 0;
  impl_->error.clear();
  impl_->changed.notify_one();
}
void OcrService::Submit(std::shared_ptr<const CapturePixels> pixels) {
  std::lock_guard lock(impl_->mutex);
  if (!impl_->ready || impl_->loading) return;
  impl_->pending = std::move(pixels); // Only the latest waiting image is retained.
  impl_->changed.notify_one();
}
void OcrService::Reset() {
  std::lock_guard lock(impl_->mutex);
  ++impl_->generation;
  ++impl_->revision;
  impl_->pending.reset();
  impl_->lines.clear();
  impl_->hash = 0;
  impl_->error.clear();
  impl_->recognized = 0;
  impl_->skipped = 0;
  impl_->duration = 0;
  impl_->width = impl_->height = 0;
}
EncodableMap OcrService::Snapshot() {
  std::lock_guard lock(impl_->mutex);
  return {{EncodableValue("ready"), EncodableValue(impl_->ready)},
          {EncodableValue("loading"), EncodableValue(impl_->loading || (!impl_->ready && impl_->busy))},
          {EncodableValue("busy"), EncodableValue(impl_->busy)},
          {EncodableValue("revision"), EncodableValue(static_cast<int64_t>(impl_->revision))},
          {EncodableValue("recognized"), EncodableValue(static_cast<int64_t>(impl_->recognized))},
          {EncodableValue("skipped"), EncodableValue(static_cast<int64_t>(impl_->skipped))},
          {EncodableValue("durationMs"), EncodableValue(impl_->duration)},
          {EncodableValue("width"), EncodableValue(impl_->width)},
          {EncodableValue("height"), EncodableValue(impl_->height)},
#ifndef NDEBUG
          {EncodableValue("detectedBoxes"), EncodableValue(impl_->detected_boxes)},
          {EncodableValue("acceptedBoxes"), EncodableValue(impl_->accepted_boxes)},
#endif
          {EncodableValue("error"), impl_->error.empty() ? EncodableValue() : EncodableValue(impl_->error)},
          {EncodableValue("lines"), EncodableValue(impl_->lines)}};
}
