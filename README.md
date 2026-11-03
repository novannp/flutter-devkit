<div align="center">

<img src="docs/logo.png" width="112" alt="Slipway logo" />

# Slipway

**An IDE for Flutter projects, with your code, devices, logs and builds in one window.**

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4)
![macOS](https://img.shields.io/badge/macOS-12%2B-000000)
![License](https://img.shields.io/badge/license-MIT-34D399)

<img src="docs/screenshot.png" width="860" alt="Slipway editor with a project open" />

</div>

## Install

**Windows:** download and run [`dist/Slipway-Setup.exe`](dist/Slipway-Setup.exe). No admin rights needed, and it upgrades over an older version, keeping your settings. The installer isn't code-signed yet: if Windows warns you, choose **More info → Run anyway**.

**macOS:** with Flutter and Xcode installed, run `sh tool/build_macos.sh` to get `dist/Slipway.dmg`. The first time, right-click the app and choose **Open**. The embedded device screen needs **System Settings → Privacy & Security → Accessibility**.

## Features

**Editor**
- Its own engine, with no WebView: multiple cursors, folding, regex find and replace, syntax colors for 14 languages
- Dart analysis: completion, snippets, errors as you type, go to definition, references, rename, quick fixes
- Follows the SDK your project pins with `fvm`
- Tabs and tools, the Agent included, share one strip: drag to reorder or split, and <kbd>Ctrl</kbd>+<kbd>Tab</kbd> returns to the tab used before
- Selecting text marks the same text around it, and colors in the code show a swatch at the end of their line
- Search and quick open leave out what git ignores
- Previews for images, PDF, fonts, ZIP/APK, Markdown, CSV, JSON and SVG

**Flutter**
- Run, hot reload and hot restart, with one shared session per device
- Debugger and widget inspector
- Packages panel for pub.dev: add, upgrade, remove, sort
- Panels for Flutter versions (`fvm`), Firebase setup (`flutterfire`) and `build_runner`
- `flutter`, `pub` and `dart` commands in the palette, including builds for the platforms your project has

**Git**
- Source Control with stage, commit, push, pull and side-by-side diffs
- Git Graph, with each commit's files and diffs
- Branch, sync and Publish in the status bar

**Agent** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>A</kbd>)
- Talk to the [Claude Code](https://claude.com/claude-code) you already have installed. Slipway runs it and never reads your credentials, and usage counts against your own plan

**Devices**
- Finds devices over USB, Wi-Fi 5555 and Wireless debugging, across subnets
- Mirrors and controls them with the device tools included, one by one or side by side
- A window per device: logcat, files, apps, terminal, network conditioning and dev toggles
- Display lab: change resolution, DPI and screen size on a real device

**Built-in extensions** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>X</kbd>, each can be turned off)
- **Emulators:** create, start, wipe, and download system images
- **Printer:** a network ESC/POS printer on TCP 9100 that shows receipts on screen
- **Work:** Jira tickets to branches to pull requests, with Bitbucket
- **Notes**, **History** (30 days of activity and crashes) and **Maintenance** (pub and Gradle caches)

## Shortcuts

Every command is in the palette, <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>. On macOS use <kbd>Cmd</kbd> in place of <kbd>Ctrl</kbd>; the menus show the exceptions.

| Keys | Action |
|---|---|
| <kbd>Ctrl</kbd>+<kbd>P</kbd> | Quick open (`main.dart:42` for a line, `@build` for a method) |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F</kbd> | Search in files |
| <kbd>F12</kbd> / <kbd>Shift</kbd>+<kbd>F12</kbd> | Definition / references |
| <kbd>F2</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> | Rename / quick fix |
| <kbd>F5</kbd> / <kbd>Shift</kbd>+<kbd>F5</kbd> | Run / stop |
| <kbd>Ctrl</kbd>+<kbd>F5</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F5</kbd> | Hot reload / hot restart |
| <kbd>F9</kbd> / <kbd>F10</kbd> / <kbd>F11</kbd> | Breakpoint / step over / step into |
| <kbd>Ctrl</kbd>+<kbd>D</kbd> / <kbd>Alt</kbd>+click | Next match / another cursor |
| <kbd>Ctrl</kbd>+<kbd>B</kbd> / <kbd>Ctrl</kbd>+<kbd>J</kbd> / <kbd>Ctrl</kbd>+<kbd>`</kbd> | Side panel / bottom panel / terminal |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>N</kbd> | New window |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> | Settings |

## Settings

Settings are JSON, and apply as soon as the file is saved. A project's file wins over your own, and your own wins over the defaults.

| File | Scope |
|---|---|
| `.slipway/settings.json` in a project | That project; commit it to share with your team |
| **Settings → Open settings.json** | You, in every project |

```jsonc
{
  "editor.fontSize": 15,
  "dart.lineLength": 120,
  "flutter.flavor": "dev",
  "flutter.dartDefines": ["API_URL=https://dev.example.com"]
}
```

`flutter.sdkPath` and `app.reopenLastProject` only work in your own file, so a cloned repo can't decide what runs on your computer.

## Troubleshooting

Errors are kept in `errors.log`: **Help → Show error log**.

| Problem | Try this |
|---|---|
| Phone doesn't show up | Same Wi-Fi as the PC, and Wireless debugging on? Click **Fix network access** on Devices |
| Device on another subnet isn't found | Add the subnet in **Settings → Devices**. The device must be on port 5555 |
| Tired of re-pairing | Device menu → **Enable port 5555** |
| `adb` keeps restarting | Another `adb` version is running. Keep just one on `PATH` |
| Jira or Bitbucket won't connect | **Work → ⚙ → Test connection** shows the exact error |
| Printer gets nothing from an emulator | Use the PC's IP, not `10.0.2.2` |

## Development

```sh
fvm install
fvm flutter pub get
fvm flutter run -d windows   # or macos
```

```powershell
.\tool\build_installer.ps1   # release build + dist/Slipway-Setup.exe, needs Inno Setup 6
```

Keep `--no-tree-shake-icons` when running `flutter build` by hand, or some icons go missing. Every push to `main` that passes CI also builds `dist-windows`, `dist-arm64` and `dist-x64`, under the run's page in **Actions**.

## Thanks

Slipway stands on the work of these people and projects. Thank you for building and sharing them.

|  | By | Project | Used for |
|---|---|---|---|
| <a href="https://github.com/felangel"><img src="https://github.com/felangel.png?size=64" width="32" height="32" alt="Felix Angelov" /></a> | [Felix Angelov](https://github.com/felangel) | [flutter_bloc](https://pub.dev/packages/flutter_bloc) | App state |
| <a href="https://github.com/TerminalStudio"><img src="https://github.com/TerminalStudio.png?size=64" width="32" height="32" alt="TerminalStudio" /></a> <a href="https://github.com/xuty"><img src="https://github.com/xuty.png?size=64" width="32" height="32" alt="xuty" /></a> | [TerminalStudio](https://github.com/TerminalStudio), [xuty](https://github.com/xuty) | [xterm](https://pub.dev/packages/xterm), [flutter_pty](https://pub.dev/packages/flutter_pty) | The terminal |
| <a href="https://github.com/Skyost"><img src="https://github.com/Skyost.png?size=64" width="32" height="32" alt="Hugo Delaunay" /></a> | [Hugo Delaunay](https://github.com/Skyost) | [bonsoir](https://pub.dev/packages/bonsoir) | Finding apps on the network |
| <a href="https://github.com/lijy91"><img src="https://github.com/lijy91.png?size=64" width="32" height="32" alt="LiJianying" /></a> <a href="https://github.com/leanflutter"><img src="https://github.com/leanflutter.png?size=64" width="32" height="32" alt="LeanFlutter" /></a> | [LiJianying](https://github.com/lijy91), [LeanFlutter](https://github.com/leanflutter) | [window_manager](https://pub.dev/packages/window_manager) | The window and title bar |
| <a href="https://github.com/dart-lang"><img src="https://github.com/dart-lang.png?size=64" width="32" height="32" alt="Dart team" /></a> | [Dart team](https://github.com/dart-lang) | [vm_service](https://pub.dev/packages/vm_service), [ffi](https://pub.dev/packages/ffi), [path](https://pub.dev/packages/path) | Debugger, native calls, file paths |
| <a href="https://github.com/flutter"><img src="https://github.com/flutter.png?size=64" width="32" height="32" alt="Flutter team" /></a> | [Flutter team](https://github.com/flutter) | [shared_preferences](https://pub.dev/packages/shared_preferences), [file_selector](https://pub.dev/packages/file_selector), [path_provider](https://pub.dev/packages/path_provider), [flutter_lints](https://pub.dev/packages/flutter_lints) | Preferences, file pickers, app folders, code checks |
| <a href="https://github.com/Genymobile"><img src="https://github.com/Genymobile.png?size=64" width="32" height="32" alt="Genymobile" /></a> <a href="https://github.com/rom1v"><img src="https://github.com/rom1v.png?size=64" width="32" height="32" alt="Romain Vimont" /></a> | [Genymobile](https://github.com/Genymobile), [Romain Vimont](https://github.com/rom1v) | [scrcpy](https://github.com/Genymobile/scrcpy) | Device screens, shipped |
| <a href="https://github.com/FFmpeg"><img src="https://github.com/FFmpeg.png?size=64" width="32" height="32" alt="FFmpeg" /></a> | [FFmpeg](https://github.com/FFmpeg) | [FFmpeg](https://ffmpeg.org) | Video for scrcpy, shipped |
| <a href="https://github.com/slouken"><img src="https://github.com/slouken.png?size=64" width="32" height="32" alt="Sam Lantinga" /></a> <a href="https://github.com/libsdl-org"><img src="https://github.com/libsdl-org.png?size=64" width="32" height="32" alt="SDL" /></a> | [Sam Lantinga](https://github.com/slouken), [SDL](https://github.com/libsdl-org) | [SDL](https://github.com/libsdl-org/SDL) | Windowing for scrcpy, shipped |
| <a href="https://github.com/libusb"><img src="https://github.com/libusb.png?size=64" width="32" height="32" alt="libusb" /></a> | [libusb](https://github.com/libusb) | [libusb](https://github.com/libusb/libusb) | USB for scrcpy, shipped |
| <a href="https://github.com/leoafarias"><img src="https://github.com/leoafarias.png?size=64" width="32" height="32" alt="Leo Farias" /></a> | [Leo Farias](https://github.com/leoafarias) | [FVM](https://github.com/btwld/fvm) | Flutter versions, the copy you install |
| <a href="https://github.com/flutter"><img src="https://github.com/flutter.png?size=64" width="32" height="32" alt="Flutter team" /></a> <a href="https://github.com/dart-lang"><img src="https://github.com/dart-lang.png?size=64" width="32" height="32" alt="Dart team" /></a> | [Flutter team](https://github.com/flutter), [Dart team](https://github.com/dart-lang) | [Flutter](https://flutter.dev) and [Dart](https://dart.dev) SDKs | Running your project, and the analysis server behind the editor |
| <a href="https://github.com/invertase"><img src="https://github.com/invertase.png?size=64" width="32" height="32" alt="Invertase" /></a> | [Invertase](https://github.com/invertase) | [FlutterFire CLI](https://github.com/invertase/flutterfire_cli) | Firebase setup, the copy you install |
| <a href="https://github.com/firebase"><img src="https://github.com/firebase.png?size=64" width="32" height="32" alt="Firebase" /></a> | [Firebase](https://github.com/firebase) | [Firebase CLI](https://github.com/firebase/firebase-tools) | Firebase setup, the copy you install |
| <a href="https://github.com/anthropics"><img src="https://github.com/anthropics.png?size=64" width="32" height="32" alt="Anthropic" /></a> | [Anthropic](https://github.com/anthropics) | [Claude Code](https://claude.com/claude-code) | The Agent, the copy you install |

[Android Debug Bridge](https://developer.android.com/tools/adb) comes from the Android Open Source Project.

Slipway is made by <a href="https://github.com/novannp"><img src="https://github.com/novannp.png?size=64" width="32" height="32" alt="Novan Noviansyah Pratama" /></a> [Novan Noviansyah Pratama](https://github.com/novannp) and [its contributors](https://github.com/novannp/flutter-devkit/graphs/contributors).

## License

[MIT](LICENSE). Everything it ships stays under its own license: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), or **Help → Licenses** in the app.

Flutter, Dart and the related logos are trademarks of Google LLC. Slipway is not endorsed by or affiliated with Google LLC. Visual Studio Code is a trademark of Microsoft Corporation. Slipway is an independent project, and these names only say what it works with.

**Slipway is not based on Visual Studio Code.** It isn't a fork and contains none of its source, and its editor engine is written from scratch in Flutter. Microsoft has no part in it. The optional VS Code themes only follow that editor's published default colors.
