#ifndef RUNNER_NATIVE_BRIDGE_H_
#define RUNNER_NATIVE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class FileDropTarget;

// System notifications and files dragged onto the window, for lib/core/native_bridge.dart.
class NativeBridge {
 public:
  NativeBridge(flutter::BinaryMessenger* messenger, HWND top_level, HWND view);
  ~NativeBridge();

  // Takes a toast click posted from its background thread; true if the message was one.
  bool HandleWindowMessage(UINT message, WPARAM wparam);

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  std::unique_ptr<Channel> channel_;
  HWND top_level_;
  HWND view_;
  FileDropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_NATIVE_BRIDGE_H_
