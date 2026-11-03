# Third-party notices

Slipway itself is under the MIT License, in `LICENSE`. It also ships or downloads the software below, which stays under its own license. Inside the app, **Help → Licenses** lists these and every Dart package.

## Programs shipped with the app

The Windows build carries these in `windows/third_party/scrcpy`, unmodified from the scrcpy 3.3.4 release. On macOS, `tool/bundle_scrcpy_macos.sh` downloads the matching scrcpy release when the app is built.

| Software | Version | License | Source |
|---|---|---|---|
| scrcpy | 3.3.4 | Apache-2.0 | https://github.com/Genymobile/scrcpy/tree/v3.3.4 |
| Android Debug Bridge (adb, and AdbWinApi and AdbWinUsbApi on Windows) | 36.0.0 | Apache-2.0, with the notices below | https://android.googlesource.com/platform/packages/modules/adb |
| FFmpeg (avcodec, avformat, avutil, swresample) | 7.1.1 | LGPL-2.1-or-later | https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz |
| libusb | 1.0.29 | LGPL-2.1-or-later | https://github.com/libusb/libusb/archive/refs/tags/v1.0.29.tar.gz |
| SDL2 | 2.32.8 | Zlib | https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.32.8.tar.gz |

The license texts are in `assets/licenses`.

### FFmpeg and libusb (LGPL)

Each GitHub release of Slipway carries the source of the versions above beside its downloads. They were built by the scrcpy project, with the scripts in https://github.com/Genymobile/scrcpy/tree/v3.3.4/app/deps and the steps in https://github.com/Genymobile/scrcpy/blob/v3.3.4/doc/build.md.

You may replace them with your own builds. On Windows they are separate `.dll` files next to `scrcpy.exe`. On macOS they are linked into the `scrcpy` program inside the app, so build scrcpy from its source with your versions and put it in `Contents/Resources/scrcpy`. Slipway only starts that program as a separate process.

### scrcpy (Apache-2.0)

Copyright (C) 2018 Genymobile
Copyright (C) 2018-2026 Romain Vimont

Licensed under the Apache License, Version 2.0, in `assets/licenses/Apache-2.0.txt`. Slipway ships its program unmodified, and starts it as a separate process. Slipway is not made by, affiliated with or endorsed by the authors of scrcpy, and it names scrcpy only to say what it uses.

### Android Debug Bridge

Copyright (C) The Android Open Source Project. Licensed under the Apache License, Version 2.0. These are the prebuilt programs from Android SDK Platform-Tools, as included in the scrcpy release. The notices Google publishes with Platform-Tools are in `assets/licenses/android-platform-tools-NOTICE-windows.txt` and `assets/licenses/android-platform-tools-NOTICE-macos.txt`. They cover the whole Platform-Tools package, of which Slipway carries only the programs named above.

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

## Tools it runs, not shipped

Slipway starts the copies of these you installed yourself. They aren't part of it, and each has its own license. Thank you to their authors.

| Software | By | License | Source |
|---|---|---|---|
| Flutter SDK | The Flutter authors | BSD-3-Clause | https://github.com/flutter/flutter |
| Dart SDK | The Dart project authors | BSD-3-Clause | https://github.com/dart-lang/sdk |
| FVM | Leo Farias and contributors | MIT | https://github.com/btwld/fvm |
| FlutterFire CLI | Invertase and contributors | Apache-2.0 | https://github.com/invertase/flutterfire_cli |
| Firebase CLI | Firebase and contributors | MIT | https://github.com/firebase/firebase-tools |
| Claude Code | Anthropic | Anthropic's terms | https://claude.com/claude-code |

## Dart and Flutter packages

The app is built with the Flutter SDK and packages from pub.dev, under BSD, MIT, Apache-2.0 and, for dbus, MPL-2.0 licenses. dbus is used unmodified, and its source is at https://pub.dev/packages/dbus. All of their licenses are included in the app, and shown on its licenses page.

## Trademarks

Flutter, Dart and the related logos are trademarks of Google LLC. Android is a trademark of Google LLC. Visual Studio Code and Windows are trademarks of Microsoft Corporation. macOS is a trademark of Apple Inc. Slipway is not endorsed by or affiliated with any of them. These names only say what the app works with.

Slipway is not based on Visual Studio Code. It isn't a fork and contains none of its source, and its editor engine is written from scratch in Flutter.

Some themes follow color schemes published by others, and carry those names to say which: One Dark, Dracula, Nord and Solarized. The VS Code themes follow the default colors of Visual Studio Code.
