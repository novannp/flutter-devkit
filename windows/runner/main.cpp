#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins. The OLE form also lets the window receive dragged files.
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Jendela workspace per device dibuka dengan --title=<nama device> dan --cascade=<n>.
  std::wstring title = L"Slipway";
  int cascade = 0;
  for (const auto& arg : command_line_arguments) {
    if (arg.rfind("--title=", 0) == 0) {
      std::string value = arg.substr(8);
      int len = ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
      if (len > 1) {
        std::wstring wide(len - 1, L'\0');
        ::MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, &wide[0], len);
        title = wide;
      }
    } else if (arg.rfind("--cascade=", 0) == 0) {
      cascade = std::atoi(arg.substr(10).c_str()) % 8;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10 + cascade * 40, 10 + cascade * 40);
  Win32Window::Size size(1440, 900);
  if (!window.Create(title, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
