#ifndef RUNNER_NATIVE_BRIDGE_H_
#define RUNNER_NATIVE_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class FileDropTarget;

// Files dragged onto the window, for lib/core/native_bridge.dart.
class NativeBridge {
 public:
  NativeBridge(flutter::BinaryMessenger* messenger, HWND view);
  ~NativeBridge();

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  std::unique_ptr<Channel> channel_;
  HWND view_;
  FileDropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_NATIVE_BRIDGE_H_
