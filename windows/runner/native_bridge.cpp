#include "native_bridge.h"

#include <flutter/standard_method_codec.h>
#include <oleidl.h>
#include <shellapi.h>

#include <string>
#include <thread>

#include "pdf_render.h"

namespace {

std::string ToUtf8(const std::wstring& text) {
  int length = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return {};
  std::string out(length - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, &out[0], length, nullptr, nullptr);
  return out;
}

constexpr UINT kPdfDone = WM_APP + 1;
constexpr wchar_t kMailboxClass[] = L"HotRestartNativeBridgeMailbox";

struct PdfJob {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  PdfPageImage image;
};

// Flutter only takes answers on the platform thread, and this window's messages arrive there.
LRESULT CALLBACK MailboxProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kPdfDone) return ::DefWindowProcW(window, message, wparam, lparam);
  std::unique_ptr<PdfJob> job(reinterpret_cast<PdfJob*>(lparam));
  if (!job->image.ok) {
    std::wstring error = job->image.error;
    while (!error.empty() && (error.back() == L'\n' || error.back() == L'\r')) error.pop_back();
    job->result->Error("pdf", ToUtf8(error));
    return 0;
  }
  job->result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("pages"), flutter::EncodableValue(job->image.pages)},
      {flutter::EncodableValue("png"), flutter::EncodableValue(std::move(job->image.png))},
  }));
  return 0;
}

std::wstring ToWide(const std::string& text) {
  int length = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (length <= 1) return {};
  std::wstring out(length - 1, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, &out[0], length);
  return out;
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

NativeBridge::NativeBridge(flutter::BinaryMessenger* messenger, HWND view) : view_(view) {
  channel_ = std::make_unique<Channel>(messenger, "hotrestart/native", &flutter::StandardMethodCodec::GetInstance());
  drop_target_ = new FileDropTarget(channel_.get());
  ::RegisterDragDrop(view_, drop_target_);

  WNDCLASSW mailbox_class = {};
  mailbox_class.lpfnWndProc = MailboxProc;
  mailbox_class.hInstance = ::GetModuleHandleW(nullptr);
  mailbox_class.lpszClassName = kMailboxClass;
  ::RegisterClassW(&mailbox_class);
  mailbox_ = ::CreateWindowExW(0, kMailboxClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, mailbox_class.hInstance, nullptr);
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "renderPdf") {
      RenderPdf(call, std::move(result));
    } else {
      result->NotImplemented();
    }
  });
}

void NativeBridge::RenderPdf(const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string* path = nullptr;
  const int* page = nullptr;
  const int* width = nullptr;
  if (args) {
    auto find = [&](const char* key) { auto it = args->find(flutter::EncodableValue(key)); return it == args->end() ? nullptr : &it->second; };
    if (auto* v = find("path")) path = std::get_if<std::string>(v);
    if (auto* v = find("page")) page = std::get_if<int>(v);
    if (auto* v = find("width")) width = std::get_if<int>(v);
  }
  if (!path || !page || !width) {
    result->Error("pdf", "Bad arguments");
    return;
  }
  std::thread([mailbox = mailbox_, wide = ToWide(*path), page = *page, width = *width, result = std::move(result)]() mutable {
    auto* job = new PdfJob{std::move(result), RenderPdfPage(wide, page, static_cast<unsigned>(width))};
    if (!::PostMessageW(mailbox, kPdfDone, 0, reinterpret_cast<LPARAM>(job))) delete job;
  }).detach();
}

NativeBridge::~NativeBridge() {
  channel_->SetMethodCallHandler(nullptr);
  if (mailbox_) ::DestroyWindow(mailbox_);
  ::RevokeDragDrop(view_);
  drop_target_->Release();
}
