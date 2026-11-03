# Third-party notices

Flutter DevKit itself is under the MIT License, in `LICENSE`. It also ships or downloads the software below, which stays under its own license. Inside the app, **Help → About Flutter DevKit → View licenses** lists these and every Dart package.

## Programs shipped with the app

The Windows build carries these in `windows/third_party/scrcpy`. On macOS, `tool/bundle_scrcpy_macos.sh` downloads the matching scrcpy release when the app is built.

| Software | Version | License | Source |
|---|---|---|---|
| scrcpy | 3.3.4 | Apache-2.0 | https://github.com/Genymobile/scrcpy |
| Android Debug Bridge (adb, AdbWinApi, AdbWinUsbApi) | 36.0.0 | Apache-2.0; distributed by Google in Android SDK Platform-Tools, as part of the scrcpy release | https://android.googlesource.com/platform/packages/modules/adb |
| FFmpeg (avcodec, avformat, avutil, swresample) | as in scrcpy 3.3.4 | LGPL-2.1-or-later | https://ffmpeg.org/download.html |
| SDL2 | as in scrcpy 3.3.4 | Zlib | https://github.com/libsdl-org/SDL |
| libusb | as in scrcpy 3.3.4 | LGPL-2.1-or-later | https://github.com/libusb/libusb |

FFmpeg and libusb are separate libraries (`.dll` files next to `scrcpy.exe`), unmodified from the scrcpy release. You may replace them with your own builds. Their source is at the links above, and the scrcpy project documents how its builds are made at https://github.com/Genymobile/scrcpy/blob/master/doc/build.md.

The license texts are in `assets/licenses`.

### SDL2 (Zlib)

Copyright (C) 1997-2025 Sam Lantinga <slouken@libsdl.org>

This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.

## Source kept in this repository

| Software | License | Where |
|---|---|---|
| flutter_pty | MIT, Copyright (c) 2022 xuty | `third_party/flutter_pty`, with its `LICENSE` |

## Dart and Flutter packages

The app is built with Flutter and packages from pub.dev, including flutter_bloc, bonsoir, shared_preferences, file_selector, path_provider, ffi, window_manager, tray_manager, xterm and vm_service. Their licenses are included in the app, and shown in its licenses page.

## Trademarks

Flutter and Dart are trademarks of Google LLC. Android is a trademark of Google LLC. Visual Studio Code is a trademark of Microsoft Corporation. macOS is a trademark of Apple Inc. Windows is a trademark of Microsoft Corporation. Flutter DevKit is an independent project and isn't affiliated with, endorsed by or sponsored by any of them. These names only say what the app works with.

Some themes follow color schemes published by others, and carry those names to say which: One Dark, Dracula, Nord and Solarized. The VS Code themes follow the default colors of Visual Studio Code.
