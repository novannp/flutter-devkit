#include "native_bridge.h"

#include <flutter/standard_method_codec.h>
#include <oleidl.h>
#include <shellapi.h>

#include <string>

namespace {

std::string ToUtf8(const std::wstring& text) {
  int length = ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (length <= 1) return {};
  std::string out(length - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, &out[0], length, nullptr, nullptr);
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
  channel_ = std::make_unique<Channel>(messenger, "devkit/native", &flutter::StandardMethodCodec::GetInstance());
  drop_target_ = new FileDropTarget(channel_.get());
  ::RegisterDragDrop(view_, drop_target_);
}

NativeBridge::~NativeBridge() {
  ::RevokeDragDrop(view_);
  drop_target_->Release();
}
