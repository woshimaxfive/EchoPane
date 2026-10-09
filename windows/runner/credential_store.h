#ifndef ECHOPANE_CREDENTIAL_STORE_H_
#define ECHOPANE_CREDENTIAL_STORE_H_
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>

class CredentialStore {
 public:
  explicit CredentialStore(flutter::FlutterEngine* engine);
 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  static void Handle(const wchar_t* target,
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::unique_ptr<Channel> channel_;
#ifndef NDEBUG
  std::unique_ptr<Channel> test_channel_;
#endif
};
#endif
