#pragma once

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct PlaybackDevice { std::string id, name; bool is_default = false; };
struct AudioState {
  bool running = false, loading = false, recognizing = false;
  std::string error, language;
  std::vector<std::string> lines;
  std::vector<PlaybackDevice> devices;
  std::vector<uint8_t> pcm;
  int64_t session = 0, revision = 0, samples = 0, dropped = 0, duration_ms = 0;
  double level = 0;
};

// Owns WASAPI and inference resources on one worker. No audio is saved to disk.
class AudioEngine {
 public:
  AudioEngine();
  ~AudioEngine();
  void Start(std::string directory, std::string device, std::string language, bool stream = false);
  void Stop();
  void Refresh();
  AudioState Snapshot();
#ifndef NDEBUG
  void Fixture(std::string directory, std::string language, std::vector<float> samples);
  void PlayFixture(std::vector<float> samples);
  void DeviceNotification(bool disconnected);
#endif
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
