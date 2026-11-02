#include "native_bridge.h"

#include <flutter/standard_method_codec.h>
#include <oleidl.h>
#include <roapi.h>
#include <shellapi.h>
#include <windows.data.xml.dom.h>
#include <windows.foundation.h>
#include <windows.ui.notifications.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>

#include <deque>
#include <string>

using ABI::Windows::Data::Xml::Dom::IXmlDocument;
using ABI::Windows::Data::Xml::Dom::IXmlDocumentIO;
using ABI::Windows::Foundation::ITypedEventHandler;
using ABI::Windows::UI::Notifications::IToastNotification;
using ABI::Windows::UI::Notifications::IToastNotificationFactory;
using ABI::Windows::UI::Notifications::IToastNotificationManagerStatics;
using ABI::Windows::UI::Notifications::IToastNotifier;
using ABI::Windows::UI::Notifications::ToastNotification;
using Microsoft::WRL::Callback;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Implements;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

const UINT kToastClicked = WM_APP + 41;
const wchar_t kAppUserModelId[] = L"FlutterDevKit";

std::string ToUtf8(const std::wstring& text) {
  int length = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return {};
  std::string out(length - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, &out[0], length, nullptr, nullptr);
  return out;
}

std::wstring ToWide(const std::string& text) {
  int length = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 1) return {};
  std::wstring out(length - 1, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &out[0], length);
  return out;
}

std::wstring EscapeXml(const std::wstring& text) {
  std::wstring out;
  for (wchar_t c : text) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out += c;
    }
  }
  return out;
}

// Windows shows a toast under this id's name and icon; a toast from an unpackaged app needs it registered.
void RegisterAppId() {
  std::wstring key = std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppUserModelId;
  HKEY handle;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &handle, nullptr) != ERROR_SUCCESS) {
    return;
  }
  const std::wstring name = L"Flutter DevKit";
  ::RegSetValueExW(handle, L"DisplayName", 0, REG_SZ, reinterpret_cast<const BYTE*>(name.c_str()), static_cast<DWORD>((name.size() + 1) * sizeof(wchar_t)));
  wchar_t exe[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    std::wstring icon(exe);
    icon = icon.substr(0, icon.find_last_of(L'\\')) + L"\\data\\flutter_assets\\assets\\logo.png";
    ::RegSetValueExW(handle, L"IconUri", 0, REG_SZ, reinterpret_cast<const BYTE*>(icon.c_str()), static_cast<DWORD>((icon.size() + 1) * sizeof(wchar_t)));
  }
  ::RegCloseKey(handle);
}

HRESULT ShowToast(HWND window, int id, const std::wstring& title, const std::wstring& body) {
  static bool registered = false;
  if (!registered) {
    RegisterAppId();
    registered = true;
  }

  std::wstring xml = L"<toast><visual><binding template=\"ToastGeneric\"><text>" + EscapeXml(title) + L"</text><text>" + EscapeXml(body) + L"</text></binding></visual></toast>";

  ComPtr<IInspectable> instance;
  HRESULT hr = ::RoActivateInstance(HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(), &instance);
  if (FAILED(hr)) return hr;
  ComPtr<IXmlDocument> document;
  if (FAILED(hr = instance.As(&document))) return hr;
  ComPtr<IXmlDocumentIO> document_io;
  if (FAILED(hr = document.As(&document_io))) return hr;
  if (FAILED(hr = document_io->LoadXml(HStringReference(xml.c_str()).Get()))) return hr;

  ComPtr<IToastNotificationFactory> factory;
  hr = ::RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(), IID_PPV_ARGS(&factory));
  if (FAILED(hr)) return hr;
  ComPtr<IToastNotification> toast;
  if (FAILED(hr = factory->CreateToastNotification(document.Get(), &toast))) return hr;

  EventRegistrationToken token;
  hr = toast->add_Activated(
      Callback<Implements<RuntimeClassFlags<ClassicCom>, ITypedEventHandler<ToastNotification*, IInspectable*>>>(
          [window, id](IToastNotification*, IInspectable*) -> HRESULT {
            ::PostMessageW(window, kToastClicked, static_cast<WPARAM>(id), 0);
            return S_OK;
          })
          .Get(),
      &token);
  if (FAILED(hr)) return hr;

  ComPtr<IToastNotificationManagerStatics> manager;
  hr = ::RoGetActivationFactory(HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(), IID_PPV_ARGS(&manager));
  if (FAILED(hr)) return hr;
  ComPtr<IToastNotifier> notifier;
  if (FAILED(hr = manager->CreateToastNotifierWithId(HStringReference(kAppUserModelId).Get(), &notifier))) return hr;
  if (FAILED(hr = notifier->Show(toast.Get()))) return hr;

  // A click only reaches the handler while the toast object lives.
  static std::deque<ComPtr<IToastNotification>> shown;
  shown.push_back(toast);
  if (shown.size() > 50) shown.pop_front();
  return S_OK;
}

}  // namespace

class FileDropTarget : public IDropTarget {
 public:
  explicit FileDropTarget(flutter::MethodChannel<flutter::EncodableValue>* channel) : channel_(channel) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (id == IID_IUnknown || id == IID_IDropTarget) {
      *out = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ::InterlockedIncrement(&references_); }

  ULONG STDMETHODCALLTYPE Release() override {
    ULONG left = ::InterlockedDecrement(&references_);
    if (left == 0) delete this;
    return left;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    has_files_ = data->QueryGetData(&format) == S_OK;
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (has_files_) channel_->InvokeMethod("dragEntered", nullptr);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = has_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (has_files_) channel_->InvokeMethod("dragExited", nullptr);
    has_files_ = false;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL, DWORD* effect) override {
    *effect = DROPEFFECT_NONE;
    has_files_ = false;
    FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium;
    if (FAILED(data->GetData(&format, &medium))) return S_OK;
    flutter::EncodableList paths;
    if (HDROP drop = static_cast<HDROP>(::GlobalLock(medium.hGlobal))) {
      UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count; i++) {
        UINT length = ::DragQueryFileW(drop, i, nullptr, 0);
        std::wstring path(length, L'\0');
        ::DragQueryFileW(drop, i, &path[0], length + 1);
        paths.push_back(flutter::EncodableValue(ToUtf8(path)));
      }
      ::GlobalUnlock(medium.hGlobal);
    }
    ::ReleaseStgMedium(&medium);
    *effect = DROPEFFECT_COPY;
    channel_->InvokeMethod("dropped", std::make_unique<flutter::EncodableValue>(paths));
    return S_OK;
  }

 private:
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  LONG references_ = 1;
  bool has_files_ = false;
};

NativeBridge::NativeBridge(flutter::BinaryMessenger* messenger, HWND top_level, HWND view) : top_level_(top_level), view_(view) {
  channel_ = std::make_unique<Channel>(messenger, "devkit/native", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "notify") {
      result->NotImplemented();
      return;
    }
    const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("bad_arguments");
      return;
    }
    const auto& id = arguments->at(flutter::EncodableValue("id"));
    const auto& title = arguments->at(flutter::EncodableValue("title"));
    const auto& body = arguments->at(flutter::EncodableValue("body"));
    HRESULT hr = ShowToast(top_level_, std::get<int32_t>(id), ToWide(std::get<std::string>(title)), ToWide(std::get<std::string>(body)));
    if (FAILED(hr)) {
      result->Error("toast_failed", std::to_string(hr));
    } else {
      result->Success();
    }
  });
  drop_target_ = new FileDropTarget(channel_.get());
  ::RegisterDragDrop(view_, drop_target_);
}

NativeBridge::~NativeBridge() {
  ::RevokeDragDrop(view_);
  drop_target_->Release();
}

bool NativeBridge::HandleWindowMessage(UINT message, WPARAM wparam) {
  if (message != kToastClicked) return false;
  channel_->InvokeMethod("notificationClicked", std::make_unique<flutter::EncodableValue>(static_cast<int32_t>(wparam)));
  return true;
}
