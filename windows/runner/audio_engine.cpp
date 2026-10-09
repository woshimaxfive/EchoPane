#include "audio_engine.h"

#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio-fixed.h"
#include "whisper.h"
#include "ggml-backend.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <stdexcept>
#include <windows.h>

namespace {
std::string Utf8(const wchar_t* value) {
  int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  result.pop_back(); return result;
}
std::wstring Wide(const std::string& value) {
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("path");
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}
struct ModelFile {
  FILE* file = nullptr;
  explicit ModelFile(const std::filesystem::path& path) { file = _wfopen(path.c_str(), L"rb"); }
  ~ModelFile() { if (file) fclose(file); }
  static size_t Read(void* p, void* output, size_t bytes) { return fread(output, 1, bytes, static_cast<ModelFile*>(p)->file); }
  static bool Eof(void* p) { return feof(static_cast<ModelFile*>(p)->file) != 0; }
  static void Close(void*) {} // RAII owns the file, including failed initialization.
  whisper_model_loader Loader() { return {this, Read, Eof, Close}; }
};
void QuietLog(enum ggml_log_level, const char*, void*) {}
}

struct AudioEngine::Impl {
  static constexpr size_t kCapacity = 16000 * 12;
  std::array<float, kCapacity> ring{};
  std::atomic<size_t> written{0}, read{0};
  std::atomic<int64_t> captured{0}, dropped{0}, generation{0};
  std::atomic<double> level{0};
  std::atomic<bool> rerouted{false}, interrupted{false};
  std::mutex mutex;
  std::condition_variable wake;
  AudioState state;
  bool quit = false, start_pending = false, refresh_pending = true;
  bool pending_stream = false, stream = false;
  std::vector<uint8_t> stream_pcm;
  std::string directory, endpoint, pending_language, language, loaded_directory;
  std::vector<float> fixture;
  std::thread worker;
  ma_context context{};
  bool context_ready = false;
  ma_device device{};
  bool device_ready = false;
#ifndef NDEBUG
  ma_device playback{};
  bool playback_ready = false, play_pending = false;
  std::vector<float> play_values, pending_play;
  std::atomic<size_t> play_position{0};
  static void Playback(ma_device* d, void* output, const void*, ma_uint32 count) {
    auto& self = *static_cast<Impl*>(d->pUserData);
    auto* values = static_cast<float*>(output);
    size_t position = self.play_position.load();
    for (size_t i = 0; i < count; ++i) values[i] = position < self.play_values.size() ? self.play_values[position++] : 0;
    self.play_position.store(position);
  }
#endif
  whisper_context* model = nullptr;
  whisper_vad_context* vad = nullptr;
  int64_t active_generation = 0;
  int64_t observed_drops = 0;
  std::vector<float> utterance, preroll;
  int speech_frames = 0, silence_frames = 0, idle_frames = 0;

  Impl() { whisper_log_set(QuietLog, nullptr); worker = std::thread([this] { Run(); }); }
  ~Impl() {
    ++generation;
    { std::lock_guard lock(mutex); quit = true; }
    wake.notify_one(); worker.join();
  }
  static void Data(ma_device* d, void*, const void* input, ma_uint32 count) {
    auto& self = *static_cast<Impl*>(d->pUserData);
    const auto* values = static_cast<const float*>(input);
    const size_t w = self.written.load(std::memory_order_relaxed);
    const size_t r = self.read.load(std::memory_order_acquire);
    const size_t available = kCapacity - (w - r);
    const size_t accepted = std::min(static_cast<size_t>(count), available);
    float peak = 0;
    for (size_t i = 0; i < accepted; ++i) {
      const float value = values && std::isfinite(values[i]) ? values[i] : 0;
      self.ring[(w + i) % kCapacity] = value;
      peak = std::max(peak, std::abs(value));
    }
    self.written.store(w + accepted, std::memory_order_release);
    self.captured.fetch_add(count);
    self.dropped.fetch_add(static_cast<int64_t>(count - accepted));
    self.level.store(std::min(1.0, static_cast<double>(peak)));
  }
  static void Notification(const ma_device_notification* n) {
    auto& self = *static_cast<Impl*>(n->pDevice->pUserData);
    if (n->type == ma_device_notification_type_rerouted) self.rerouted = true;
    if (n->type == ma_device_notification_type_stopped) self.interrupted = true;
  }
  static bool Abort(void* value) {
    auto& self = *static_cast<Impl*>(value);
    return self.generation.load() != self.active_generation || self.rerouted.load() || self.interrupted.load();
  }
  void ClearSegment() {
    utterance.clear(); preroll.clear(); speech_frames = silence_frames = idle_frames = 0;
    if (vad) whisper_vad_reset_state(vad);
  }
  void CloseDevice() {
#ifndef NDEBUG
    if (playback_ready) { ma_device_uninit(&playback); playback_ready = false; }
#endif
    if (device_ready) { ma_device_uninit(&device); device_ready = false; }
    read = 0; written = 0; level = 0; rerouted = false; interrupted = false;
    ClearSegment();
    { std::lock_guard lock(mutex); stream_pcm.clear(); }
  }
  void Enumerate() {
    if (!context_ready) {
      const ma_backend backend = ma_backend_wasapi;
      if (ma_context_init(&backend, 1, nullptr, &context) != MA_SUCCESS) throw std::runtime_error("device");
      context_ready = true;
    }
    ma_device_info* output = nullptr; ma_uint32 count = 0;
    if (ma_context_get_devices(&context, &output, &count, nullptr, nullptr) != MA_SUCCESS) throw std::runtime_error("device");
    std::vector<PlaybackDevice> devices;
    for (ma_uint32 i = 0; i < count; ++i) devices.push_back({Utf8(output[i].id.wasapi), output[i].name, output[i].isDefault != 0});
    std::lock_guard lock(mutex); state.devices = std::move(devices);
  }
  void Load(const std::string& path) {
    if (path == loaded_directory && model && vad) return;
    static std::once_flag backends;
    std::call_once(backends, [] {
      wchar_t executable[32768];
      const DWORD size = GetModuleFileNameW(nullptr, executable, static_cast<DWORD>(std::size(executable)));
      if (size == 0 || size >= std::size(executable)) throw std::runtime_error("backend");
      const auto directory = std::filesystem::path(executable).parent_path();
      // Search the packaged directory instead of the working directory.
      ggml_backend_load_all_from_path(Utf8(directory.c_str()).c_str());
    });
    if (model) whisper_free(model); model = nullptr;
    if (vad) whisper_vad_free(vad); vad = nullptr;
    loaded_directory.clear();
    const std::filesystem::path root(Wide(path));
    ModelFile weights(root / L"ggml-base.bin");
    ModelFile activity(root / L"ggml-silero-v6.2.0.bin");
    if (!weights.file || !activity.file) throw std::runtime_error("model");
    auto loader = weights.Loader();
    auto options = whisper_context_default_params(); options.use_gpu = false;
    model = whisper_init_with_params(&loader, options);
    if (!model) throw std::runtime_error("model");
    auto vad_loader = activity.Loader();
    auto vad_options = whisper_vad_default_context_params(); vad_options.use_gpu = false; vad_options.n_threads = 1;
    vad = whisper_vad_init_with_params(&vad_loader, vad_options);
    if (!vad) throw std::runtime_error("model");
    loaded_directory = path;
  }
  void Recognize(std::vector<float> values) {
    if (values.size() < 4000 || Abort(this)) return;
    const auto begin = std::chrono::steady_clock::now();
    { std::lock_guard lock(mutex); if (Abort(this)) return; state.recognizing = true; }
    // A short silent tail preserves sentence endings without sharing old text context.
    values.resize(std::max(values.size() + 8000, static_cast<size_t>(16000)), 0);
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = 4; params.translate = false; params.no_context = true;
    params.no_timestamps = true; params.single_segment = true;
    params.print_progress = false; params.print_realtime = false;
    params.print_timestamps = false; params.print_special = false;
    params.language = language.c_str(); params.suppress_nst = true;
    params.temperature = 0; params.temperature_inc = 0;
    params.abort_callback = Abort; params.abort_callback_user_data = this;
    const int result = whisper_full(model, params, values.data(), static_cast<int>(values.size()));
    if (Abort(this)) return;
    std::vector<std::string> lines;
    if (result == 0) {
      for (int i = 0; i < whisper_full_n_segments(model); ++i) {
        if (whisper_full_get_segment_no_speech_prob(model, i) > 0.6f) continue;
        std::string text(whisper_full_get_segment_text(model, i));
        const auto first = text.find_first_not_of(" \r\n\t");
        if (first == std::string::npos) continue;
        text = text.substr(first, text.find_last_not_of(" \r\n\t") - first + 1);
        if (text.size() <= 8000) lines.push_back(std::move(text));
      }
    }
    std::lock_guard lock(mutex);
    if (Abort(this)) return;
    state.recognizing = false;
    state.duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - begin).count();
    if (result != 0) { state.error = "recognition"; return; }
    state.language = whisper_lang_str(whisper_full_lang_id(model));
    if (!lines.empty()) { state.lines = std::move(lines); ++state.revision; }
  }
  void Frame(const float* values) {
    if (!whisper_vad_detect_speech_no_reset(vad, values, 512)) throw std::runtime_error("vad");
    const bool speech = whisper_vad_n_probs(vad) > 0 && whisper_vad_probs(vad)[0] >= 0.5f;
    if (utterance.empty() && !speech) {
      preroll.insert(preroll.end(), values, values + 512);
      if (preroll.size() > 512 * 10) preroll.erase(preroll.begin(), preroll.begin() + 512);
      if (++idle_frames == 250) { std::lock_guard lock(mutex); state.lines.clear(); ++state.revision; }
      return;
    }
    idle_frames = 0;
    if (utterance.empty()) utterance.swap(preroll);
    utterance.insert(utterance.end(), values, values + 512);
    if (speech) { ++speech_frames; silence_frames = 0; } else ++silence_frames;
    if (silence_frames >= 20 || utterance.size() >= 16000 * 6) {
      auto segment = std::move(utterance);
      const bool enough = speech_frames >= 8;
      ClearSegment();
      if (enough) Recognize(std::move(segment));
    }
  }
  void Run() {
    while (true) {
      try {
        bool start = false, refresh = false, next_stream = false;
        std::string next_directory, next_endpoint, next_language;
        std::vector<float> next_fixture;
        int64_t token = 0;
        {
          std::unique_lock lock(mutex);
          if (!start_pending && !refresh_pending && !device_ready && !quit)
            wake.wait(lock, [this] { return start_pending || refresh_pending || quit || active_generation != generation.load(); });
          if (quit) break;
          start = start_pending; refresh = refresh_pending;
          start_pending = refresh_pending = false;
          if (start) { next_directory = directory; next_endpoint = endpoint; next_language = pending_language; next_stream = pending_stream; next_fixture.swap(fixture); token = generation.load(); }
        }
        if (active_generation != generation.load()) { CloseDevice(); active_generation = generation.load(); }
        if (refresh || start) Enumerate();
        if (start) {
          if (token != generation.load()) continue;
          active_generation = token;
          CloseDevice(); captured = 0; dropped = 0;
          observed_drops = 0;
          stream = next_stream;
          if (!stream) Load(next_directory);
          if (token != generation.load()) continue;
          language = next_language;
          if (!next_fixture.empty()) {
            { std::lock_guard lock(mutex); if (token != generation.load()) continue; state.loading = false; state.running = true; }
            Recognize(std::move(next_fixture));
          } else {
            ma_device_id selected{};
            if (!next_endpoint.empty()) {
              const auto id = Wide(next_endpoint);
              if (id.size() >= std::size(selected.wasapi)) throw std::runtime_error("device");
              std::copy(id.begin(), id.end(), selected.wasapi);
            }
            auto config = ma_device_config_init(ma_device_type_loopback);
            config.capture.pDeviceID = next_endpoint.empty() ? nullptr : &selected;
            config.capture.format = ma_format_f32; config.capture.channels = 1; config.sampleRate = 16000;
            config.wasapi.noAutoConvertSRC = MA_TRUE;
            config.dataCallback = Data; config.notificationCallback = Notification; config.pUserData = this;
            if (ma_device_init(&context, &config, &device) != MA_SUCCESS) throw std::runtime_error("device");
            device_ready = true;
            if (ma_device_start(&device) != MA_SUCCESS) throw std::runtime_error("device");
            std::lock_guard lock(mutex); if (token != generation.load()) continue; state.loading = false; state.running = true;
          }
        }
        if (device_ready) {
#ifndef NDEBUG
          std::vector<float> next_play;
          { std::lock_guard lock(mutex); if (play_pending) { play_pending = false; next_play.swap(pending_play); } }
          if (!next_play.empty()) {
            if (playback_ready) { ma_device_uninit(&playback); playback_ready = false; }
            play_values.swap(next_play); play_position = 0;
            auto config = ma_device_config_init(ma_device_type_playback);
            config.playback.format = ma_format_f32; config.playback.channels = 1; config.sampleRate = 16000;
            config.dataCallback = Playback; config.pUserData = this;
            if (ma_device_init(&context, &config, &playback) != MA_SUCCESS) throw std::runtime_error("playback");
            playback_ready = true;
            if (ma_device_start(&playback) != MA_SUCCESS) throw std::runtime_error("playback");
          }
#endif
          if (generation.load() != active_generation) continue;
          const int64_t losses = dropped.load();
          if (losses != observed_drops) {
            observed_drops = losses;
            read.store(written.load()); ClearSegment();
            std::lock_guard lock(mutex); state.lines.clear(); state.recognizing = false; ++state.session; ++state.revision;
          }
          if (rerouted.exchange(false)) {
            read.store(written.load()); ClearSegment();
            std::lock_guard lock(mutex); state.lines.clear(); state.recognizing = false; ++state.session; ++state.revision;
          }
          if (interrupted.load()) throw std::runtime_error("device");
          const size_t r = read.load(std::memory_order_relaxed), w = written.load(std::memory_order_acquire);
          if (w - r >= 512) {
            std::array<float, 512> frame;
            for (size_t i = 0; i < 512; ++i) frame[i] = ring[(r + i) % kCapacity];
            read.store(r + 512, std::memory_order_release);
            if (stream) {
              std::lock_guard lock(mutex);
              if (active_generation != generation.load()) continue;
              if (stream_pcm.size() + frame.size() * 2 > 16000 * 2 * 2) throw std::runtime_error("stream_overflow");
              for (float value : frame) {
                const auto pcm = static_cast<int16_t>(std::lround(std::clamp(value, -1.0f, 1.0f) * 32767));
                stream_pcm.push_back(static_cast<uint8_t>(pcm & 0xff));
                stream_pcm.push_back(static_cast<uint8_t>((static_cast<uint16_t>(pcm) >> 8) & 0xff));
              }
            } else Frame(frame.data());
          } else std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
      } catch (...) {
        CloseDevice();
        std::lock_guard lock(mutex);
        if (active_generation != generation.load()) continue;
        state.loading = state.running = state.recognizing = false;
        state.lines.clear(); state.error = "audio"; ++state.revision;
      }
    }
    CloseDevice();
    if (model) whisper_free(model);
    if (vad) whisper_vad_free(vad);
    if (context_ready) ma_context_uninit(&context);
  }
};

AudioEngine::AudioEngine() : impl_(std::make_unique<Impl>()) {}
AudioEngine::~AudioEngine() = default;
void AudioEngine::Start(std::string directory, std::string device, std::string language, bool stream) {
  std::lock_guard lock(impl_->mutex);
  ++impl_->generation;
  impl_->directory = std::move(directory); impl_->endpoint = std::move(device); impl_->pending_language = std::move(language);
  impl_->pending_stream = stream; impl_->stream_pcm.clear();
  impl_->fixture.clear(); impl_->start_pending = true;
  impl_->state.loading = true; impl_->state.running = impl_->state.recognizing = false;
  impl_->state.error.clear(); impl_->state.lines.clear(); ++impl_->state.session; ++impl_->state.revision;
  impl_->state.duration_ms = 0; impl_->state.language.clear();
  impl_->wake.notify_one();
}
void AudioEngine::Stop() {
  std::lock_guard lock(impl_->mutex);
  ++impl_->generation; impl_->start_pending = false; impl_->fixture.clear();
  impl_->stream_pcm.clear();
  impl_->state.running = impl_->state.loading = impl_->state.recognizing = false;
  impl_->state.lines.clear(); impl_->state.error.clear(); ++impl_->state.session; ++impl_->state.revision;
  impl_->wake.notify_one();
}
void AudioEngine::Refresh() { std::lock_guard lock(impl_->mutex); impl_->refresh_pending = true; impl_->wake.notify_one(); }
AudioState AudioEngine::Snapshot() {
  std::lock_guard lock(impl_->mutex); auto value = impl_->state;
  value.pcm.swap(impl_->stream_pcm);
  value.samples = impl_->captured.load(); value.dropped = impl_->dropped.load(); value.level = impl_->level.load();
  return value;
}
#ifndef NDEBUG
void AudioEngine::Fixture(std::string directory, std::string language, std::vector<float> samples) {
  std::lock_guard lock(impl_->mutex);
  ++impl_->generation;
  impl_->directory = std::move(directory); impl_->endpoint.clear(); impl_->pending_language = std::move(language);
  impl_->pending_stream = false;
  impl_->fixture = std::move(samples); impl_->start_pending = true;
  impl_->state.loading = true; impl_->state.running = impl_->state.recognizing = false;
  impl_->state.error.clear(); impl_->state.lines.clear(); ++impl_->state.session; ++impl_->state.revision;
  impl_->wake.notify_one();
}
void AudioEngine::PlayFixture(std::vector<float> samples) {
  std::lock_guard lock(impl_->mutex); impl_->pending_play = std::move(samples); impl_->play_pending = true;
}
void AudioEngine::DeviceNotification(bool disconnected) {
  if (disconnected) impl_->interrupted = true; else impl_->rerouted = true;
}
#endif
