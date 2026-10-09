#include "credential_store.h"
#include <windows.h>
#include <wincred.h>
#include <string>

CredentialStore::CredentialStore(flutter::FlutterEngine* engine) {
  channel_ = std::make_unique<Channel>(engine->messenger(), "echopane/credentials",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    Handle(L"EchoPane.TranslationKey.v1", call, std::move(result));
  });
#ifndef NDEBUG
  test_channel_ = std::make_unique<Channel>(engine->messenger(), "echopane/credentials_test",
      &flutter::StandardMethodCodec::GetInstance());
  test_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    Handle(L"EchoPane.TranslationKey.test", call, std::move(result));
  });
#endif
}

void CredentialStore::Handle(const wchar_t* target,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "read") {
    PCREDENTIALW credential = nullptr;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &credential)) {
      if (GetLastError() == ERROR_NOT_FOUND) result->Success();
      else result->Error("credential_read", "无法读取 Windows 凭据，请检查登录会话");
      return;
    }
    std::string value;
    if (credential->CredentialBlob && credential->CredentialBlobSize)
      value.assign(reinterpret_cast<const char*>(credential->CredentialBlob), credential->CredentialBlobSize);
    SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
    CredFree(credential);
    result->Success(flutter::EncodableValue(value));
    SecureZeroMemory(value.data(), value.size());
  } else if (call.method_name() == "write") {
    const auto* key = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!key || key->empty() || key->size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      result->Error("credential_size", "API Key 为空或超出 Windows 凭据大小限制");
      return;
    }
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(target);
    credential.UserName = const_cast<wchar_t*>(L"EchoPane");
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.CredentialBlobSize = static_cast<DWORD>(key->size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(key->data()));
    if (!CredWriteW(&credential, 0)) result->Error("credential_write", "无法保存 Windows 凭据，请检查登录会话");
    else result->Success();
  } else if (call.method_name() == "delete") {
    if (!CredDeleteW(target, CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND)
      result->Error("credential_delete", "无法删除 Windows 凭据，请重试");
    else result->Success();
  } else {
    result->NotImplemented();
  }
}
