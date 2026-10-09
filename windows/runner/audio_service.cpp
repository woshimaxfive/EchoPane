#include "audio_service.h"
#include <flutter/standard_method_codec.h>
#include <cstring>
#include <cmath>
#include <stdexcept>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
std::string String(const Map& values, const char* key) {
  auto found = values.find(Value(key));
  if (found == values.end() || !std::holds_alternative<std::string>(found->second)) return {};
  return std::get<std::string>(found->second);
}
Value Encode(const AudioState& state) {
  flutter::EncodableList devices, lines;
  for (const auto& device : state.devices) devices.emplace_back(Map{
    {Value("id"), Value(device.id)}, {Value("name"), Value(device.name)}, {Value("default"), Value(device.is_default)}});
  for (const auto& line : state.lines) lines.emplace_back(line);
  return Value(Map{
    {Value("running"), Value(state.running)}, {Value("loading"), Value(state.loading)},
    {Value("recognizing"), Value(state.recognizing)}, {Value("error"), Value(state.error)},
    {Value("language"), Value(state.language)}, {Value("lines"), Value(lines)}, {Value("devices"), Value(devices)},
    {Value("session"), Value(state.session)}, {Value("revision"), Value(state.revision)},
    {Value("samples"), Value(state.samples)}, {Value("dropped"), Value(state.dropped)},
    {Value("durationMs"), Value(state.duration_ms)}, {Value("level"), Value(state.level)}});
}
}
AudioService::AudioService(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(engine->messenger(),
    "echopane/audio", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    try {
      const auto& name = call.method_name();
      const auto* arguments = call.arguments();
      const Map empty;
      const auto& values = arguments && std::holds_alternative<Map>(*arguments) ? std::get<Map>(*arguments) : empty;
      if (name == "snapshot") { result->Success(Encode(audio_.Snapshot())); return; }
      if (name == "stop") { audio_.Stop(); result->Success(); return; }
      if (name == "refresh") { audio_.Refresh(); result->Success(); return; }
#ifndef NDEBUG
      if (name == "debugReroute" || name == "debugDisconnect") {
        audio_.DeviceNotification(name == "debugDisconnect"); result->Success(); return;
      }
      if (name == "debugPlay") {
        auto item = values.find(Value("pcm"));
        if (item == values.end() || !std::holds_alternative<std::vector<uint8_t>>(item->second)) throw std::runtime_error("fixture");
        const auto& bytes = std::get<std::vector<uint8_t>>(item->second);
        if (bytes.size() < 16000 || bytes.size() > 16000 * 30 * 4 || bytes.size() % 4) throw std::runtime_error("fixture");
        std::vector<float> samples(bytes.size() / 4); memcpy(samples.data(), bytes.data(), bytes.size());
        for (float value : samples) if (!std::isfinite(value) || std::abs(value) > 1) throw std::runtime_error("fixture");
        audio_.PlayFixture(std::move(samples)); result->Success(); return;
      }
#endif
      if (name == "start"
#ifndef NDEBUG
          || name == "debugFixture"
#endif
      ) {
        const auto directory = String(values, "directory"), device = String(values, "device"), language = String(values, "language");
        if (directory.empty() || directory.size() > 4096 || device.size() > 2048 ||
            (language != "auto" && language != "en" && language != "ja")) throw std::runtime_error("arguments");
#ifndef NDEBUG
        if (name == "debugFixture") {
          auto item = values.find(Value("pcm"));
          if (item == values.end() || !std::holds_alternative<std::vector<uint8_t>>(item->second)) throw std::runtime_error("fixture");
          const auto& bytes = std::get<std::vector<uint8_t>>(item->second);
          if (bytes.size() < 16000 || bytes.size() > 16000 * 30 * 4 || bytes.size() % 4) throw std::runtime_error("fixture");
          std::vector<float> samples(bytes.size() / 4); memcpy(samples.data(), bytes.data(), bytes.size());
          for (float value : samples) if (!std::isfinite(value) || std::abs(value) > 1) throw std::runtime_error("fixture");
          audio_.Fixture(directory, language, std::move(samples));
          result->Success(); return;
        }
#endif
        audio_.Start(directory, device, language); result->Success(); return;
      }
      result->NotImplemented();
    } catch (...) { result->Error("audio", "无法执行系统音频操作"); }
  });
}
AudioService::~AudioService() { channel_->SetMethodCallHandler(nullptr); audio_.Stop(); }
