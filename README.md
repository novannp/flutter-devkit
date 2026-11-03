<div align="center">

<img src="docs/logo.png" width="112" alt="Flutter DevKit logo" />

# Flutter DevKit

**The Flutter workbench: one window for your code, devices, logs and builds.**

Edit code, find devices, mirror them, read logs, hot reload, and fake printers, all without leaving one window.

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-12%2B-000000?logo=apple&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-desktop-02569B?logo=flutter&logoColor=white)
![scrcpy](https://img.shields.io/badge/scrcpy-3.3.4%20bundled-10B981)
![No setup](https://img.shields.io/badge/adb%20%26%20scrcpy-included-34D399)

[Install](#-install) · [Features](#-features) · [Shortcuts](#%EF%B8%8F-workspace-shortcuts) · [First run](#-first-run) · [Troubleshooting](#-troubleshooting) · [Development](#%EF%B8%8F-development)

<img src="docs/screenshot.png" width="860" alt="Flutter DevKit editor with a Flutter project open" />

</div>

---

## 🚀 Install

1. Download **[`dist/DevKit-Setup.exe`](dist/DevKit-Setup.exe)** and run it.
2. That's it. No admin rights needed, and `adb` + `scrcpy` are already inside.

To upgrade, run the newer setup over the old one. Flutter DevKit is closed for you, and settings from builds with the previous name carry over.

> [!NOTE]
> The installer isn't code-signed yet, so Windows may show **"Windows protected your PC"**. Click **More info → Run anyway**. Copying it from a shared folder instead of downloading usually avoids the prompt.

### macOS

Build it on a Mac with Flutter and Xcode installed: `sh tool/build_macos.sh` makes `dist/FlutterDevKit.dmg`, and downloads the `scrcpy` and `adb` that go inside the app.

- Shortcuts use <kbd>Cmd</kbd> where this page says <kbd>Ctrl</kbd>, and the menus show them that way. <kbd>Ctrl</kbd>+<kbd>Space</kbd>, <kbd>Ctrl</kbd>+<kbd>Tab</kbd> and <kbd>Ctrl</kbd>+<kbd>`</kbd> stay as they are, because macOS keeps the Cmd versions for itself. Back and forward are <kbd>Ctrl</kbd>+<kbd>-</kbd> and <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>-</kbd>, and <kbd>Option</kbd>+<kbd>←→</kbd> moves by word.
- The embedded device screen needs one permission: **System Settings → Privacy & Security → Accessibility**. macOS can't put another app's window inside this one, so the screen floats exactly over its area and follows the window. While a tooltip or snackbar covers it, it hides for a moment instead of cutting a hole.
- The first time it's unsigned: right-click the app and choose **Open**.

## 💡 Why you'll love it

Testing Flutter apps on real devices used to mean: check the IP in Settings, `adb connect`, open scrcpy, another terminal for logcat, another for `flutter run`, then hunt for a real printer. Flutter DevKit does all of it in one window:

- ✍️ **Edits your code** in its own fast editor, with multiple cursors and full Dart analysis, using the SDK your project pins with fvm
- 🔍 **Finds every device** on your network, across subnets: USB, Wi-Fi 5555, and Wireless debugging
- 🖥️ **Mirrors and controls** devices at 60 fps, one by one or side by side
- 🔥 **Flutter run, hot reload, hot restart** next to the live screen and logcat
- 🧾 **Prints receipts without a printer**, straight on screen
- 👥 **Shows who's using which tablet** across the team
- 🗂️ **Jira ticket → branch → PR** without leaving Flutter DevKit

## ✨ Features

### ✍️ Editor

Flutter DevKit opens on the Editor, and everything else opens around it. The editor is our own, written for Flutter DevKit: no WebView and no third-party editor package. It only lays out the lines in view, so large files stay smooth, and the caret, scrolling and panels all move instead of jumping.

**Writing code**

- **Multiple cursors**: <kbd>Ctrl</kbd>+<kbd>D</kbd> adds the next match, <kbd>Alt</kbd>+click adds a cursor anywhere, and typing, deleting and moving apply to all of them
- **Editing**: auto-closing brackets and quotes, smart Home and Enter, line moves and copies, comments, code folding, find and replace with regex, undo that groups typing, word wrap and zoom
- **Colors**: syntax highlighting for Dart, YAML, JSON, XML, Kotlin, Gradle, Swift, Java, C/C++, JavaScript, CSS, Markdown, Bash and PowerShell. In Dart the analyzer's colors go on top, and matching brackets light up at the caret
- **Tabs**: drag to reorder, split into views with <kbd>Ctrl</kbd>+<kbd>\\</kbd>, right click to move a tab between views. A file shows in one view at a time. Each project remembers its tabs, and tabs follow changes on disk without ever overwriting unsaved edits

**Understanding code**

- **Language features**: completion with auto-import and docs beside each suggestion, Flutter and Dart snippets (`stless`, `stful`, `stanim`, `for`, `forin`...) with Tab between placeholders, parameter hints, errors as you type, formatted hover docs, rename, quick fixes
- **Go anywhere**: <kbd>Ctrl</kbd>+click a usage to reach its definition, even inside the Flutter SDK or a package (those open read-only). <kbd>Ctrl</kbd>+click a declaration for an overlay of its usages, grouped by file
- **Breadcrumb** from the folder down to the method. Click a folder to list what's inside, or a symbol to jump to its neighbours
- **Follows fvm**: analysis, `flutter` commands and the terminal use the SDK in `.fvm` / `.fvmrc`, or the one on `PATH`. The status bar shows the Flutter and Dart versions and the analyzer's progress
- **Dart settings** per project, under the options button: line length, format on save, TODOs in Problems, folders the analyzer skips. A `page_width` in `analysis_options.yaml` wins

**Running and debugging**

- **Flutter**: run on a device or Windows, hot reload on save, hot restart, `pub get` and friends. Output is colored by level, honours ANSI colors, and lines with a `lib/…:line` open that spot
- **Run menu**: pick a device, or start an emulator from it, normally or with a cold boot. The phone button docks the device's screen beside the code
- **Widget inspector**: the Widgets tab of the bottom panel shows the running app's widget tree. Click a widget for its properties and source, pick one on the device, or show layout bounds
- **Debugger**: breakpoints in the gutter (a faint dot on hover shows where a click puts one), step over/into/out, call stack, variables you can expand, evaluate in a frame, pause on exceptions. It connects by itself when you press Run

**Project and team**

- **Source Control**: changed files, stage, commit, push and pull, branches, discard one file or everything at once (a copy stays in `git stash`), a side by side before and after diff in its own tab, gutter marks for lines that differ from `HEAD`, and line blame at the end of the current line (**Git: Toggle Line Blame** in the palette or the right-click menu)
- **Move tabs around**: drag any tab along its strip, drop a file's tab in another view to move it there, or on the left or right edge of a view to split it in two
- **Open Recent** under File lists your project folders, and reopens each with the tabs it had
- **Find things**: fuzzy quick open (`online payment` finds `online_payment.dart`, `main.dart:42` jumps to the line), search in files as you type, Open File and Open Recent
- **One left panel** switches between files, Source Control, search and debug. The terminal and Problems are in the bottom panel, running in the open project
- **Notifications** in the corner, such as when packages are missing or out of sync, with a button to run `pub get`
- **File previews**: images, PDFs, fonts and what's inside a ZIP, APK or AAB open in a tab, and anything else binary as hex. Markdown, CSV, JSON and SVG switch between code and preview (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>V</kbd>), and the preview follows your unsaved text
- **Packages** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>B</kbd>): search pub.dev and add a dependency or dev dependency, see which packages are behind, upgrade or remove one, upgrade everything including major versions, sort `pubspec.yaml` A–Z, and run the other pub commands from one panel
- **Code generation**: a project with `build_runner` gets a button in the toolbar to generate once, generate on every save, or clear its cache, with a Stop button while it runs
- **`pub get` on save**: saving `pubspec.yaml` runs it by itself; turn it off in the project's Dart settings
- **Extensions** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>X</kbd>): Device Manager, Emulators, Printer, Notes, Maintenance, History and Work are built in and can be turned off. They open as tabs beside the code, so the Editor stays where it is
- **Settings**: grouped into General, Editor, Dart, Flutter, Projects, Devices and Tools, with a search box across all of them. An Android SDK in an unusual folder can be chosen under Tools
- **Your window**: floating panels on a colored canvas, 13 themes under File, Edit menu commands for whichever field has focus, a title bar of Flutter DevKit's own, and a layout that folds its menus into one button on small screens

| Keys | Action |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> / <kbd>Ctrl</kbd>+<kbd>O</kbd> | Save / save all / open file |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> | Command palette: every command, searchable |
| <kbd>Ctrl</kbd>+<kbd>P</kbd> / <kbd>Ctrl</kbd>+<kbd>G</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>O</kbd> | Quick open / go to line / go to symbol in file |
| <kbd>Ctrl</kbd>+<kbd>F</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F</kbd> | Find / search in files |
| <kbd>Ctrl</kbd>+<kbd>Space</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Space</kbd> / <kbd>F1</kbd> | Completion / parameter hints / show docs |
| <kbd>F12</kbd> / <kbd>Shift</kbd>+<kbd>F12</kbd> | Go to definition / find references (also on right click) |
| <kbd>Ctrl</kbd>+click | On a usage: go to its definition. On a declaration: an overlay of its usages, grouped by file |
| <kbd>F2</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> / <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>F</kbd> | Rename / quick fix / format |
| <kbd>F5</kbd> / <kbd>Shift</kbd>+<kbd>F5</kbd> | Run / stop |
| <kbd>Ctrl</kbd>+<kbd>F5</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F5</kbd> | Hot reload / hot restart |
| <kbd>F9</kbd> / <kbd>F6</kbd> | Toggle breakpoint / pause (<kbd>F5</kbd> continues) |
| <kbd>F10</kbd> / <kbd>F11</kbd> / <kbd>Shift</kbd>+<kbd>F11</kbd> | Step over / into / out |
| <kbd>Ctrl</kbd>+<kbd>B</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>E</kbd> / <kbd>G</kbd> / <kbd>D</kbd> / <kbd>M</kbd> / <kbd>U</kbd> | Toggle side panel / files / Source Control / debug / problems / output |
| <kbd>Ctrl</kbd>+<kbd>D</kbd> / <kbd>Alt</kbd>+click / <kbd>Esc</kbd> | Select the word, then add a cursor at each next match / add a cursor / back to one |
| <kbd>Ctrl</kbd>+<kbd>/</kbd> / <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>A</kbd> | Line / block comment |
| <kbd>Ctrl</kbd>+<kbd>L</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>K</kbd> | Select / delete line |
| <kbd>Alt</kbd>+<kbd>↑↓</kbd> / <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>↑↓</kbd> | Move / copy lines |
| <kbd>Ctrl</kbd>+<kbd>Enter</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Enter</kbd> | Insert line below / above |
| <kbd>Ctrl</kbd>+<kbd>]</kbd> / <kbd>Ctrl</kbd>+<kbd>[</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>[</kbd> / <kbd>]</kbd> | Indent / outdent / fold / unfold |
| <kbd>Ctrl</kbd>+<kbd>H</kbd> / <kbd>F3</kbd> | Replace / next match |
| <kbd>Ctrl</kbd>+<kbd>+</kbd> / <kbd>-</kbd> / <kbd>0</kbd> / <kbd>Alt</kbd>+<kbd>Z</kbd> | Zoom in / out / reset / word wrap |
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> / <kbd>Alt</kbd>+<kbd>←→</kbd> / <kbd>F8</kbd> | Next tab / back and forward / next problem |
| <kbd>Ctrl</kbd>+<kbd>,</kbd> | Settings |
| <kbd>Ctrl</kbd>+<kbd>J</kbd> / <kbd>Ctrl</kbd>+<kbd>`</kbd> | Toggle panel / terminal |

### ⚙️ Settings files

Settings live in JSON you can edit by hand or from the Settings page, and changes apply as soon as the file is saved. A project's file wins over your own, and your own wins over the defaults. Comments and trailing commas are fine.

| File | Scope |
|---|---|
| `.devkit/settings.json` in a project | That project; commit it to share with your team |
| `settings.json` in the app's data folder (**Settings → Open settings.json**) | You, in every project |

```jsonc
{
  "editor.fontSize": 15,
  "editor.fontFamily": "JetBrains Mono",
  "editor.autoSave": "afterDelay",
  "dart.lineLength": 120,
  "dart.organizeImportsOnSave": true,
  "flutter.flavor": "dev",
  "flutter.target": "lib/main_dev.dart",
  "flutter.dartDefines": ["API_URL=https://dev.example.com"]
}
```

`flutter.sdkPath`, `app.keepRunningOnClose` and `app.reopenLastProject` only work in your own file: a repo you clone shouldn't decide what program runs on your computer. Run arguments with shell characters such as `&` or `|` are left out, and Run tells you when that happens.

## 📡 Devices

- **Auto-discovery** over USB, `adb` Wi-Fi (5555), and Wireless debugging (mDNS)
- **Pair** by QR, pairing code, or IP; **skip pairing** by plugging in USB once and tapping *Always allow*
- **Auto-switch to port 5555** so devices reconnect over Wi-Fi without pairing until reboot
- Shows which of **your apps and versions** are installed (detected from your project folders)
- **Scan across subnets**: add other subnets in **Settings → Devices**; subnets of devices seen before are included automatically
- **In use by You**: shows which devices you have open, on USB, or marked *I'm using this*
- **Find**: makes a device blink and vibrate so you can spot it among identical tablets
- **Name label wallpaper**: name, IP, model, serial and a QR as the wallpaper (tap *Wallpaper* once on the device)

### 🪟 Device workspace

Each device opens in **its own window**, made for multi-device testing.

- **Screen mirror**: Fast (embedded scrcpy) or Lite (screenshots), auto-sized to the device with no black bars
- **Logcat** with crash detection, plus Files, Apps, Info and an interactive **terminal** (`adb shell`, Git Bash or PowerShell)
- **Flutter** run / attach, hot reload / restart, install the latest build
- **Click to open source**: `package:…/file.dart:142:7` in logs opens in VS Code at that line, using the exact branch or local clone of each package the app uses
- **Network conditioning**: 2G/3G/4G speed limit (Android 12+), emulator profiles, **connection drop / flaky network** that recovers by itself
- **Dev toggles**: show touches, layout bounds, animations, dark mode, font size, fake battery level

### 📐 Display lab

- Change **resolution, DPI and screen size** on a real device
- Presets from a 5.5" phone to a **21.5" POS** and **43" 4K signage**
- Shows the resulting **dp size and breakpoint**

### 📱 Emulators

- Start, cold boot, headless, stop, **wipe data**, edit hardware, delete
- Create AVDs from **size presets** (phone, tablet, POS, kiosk, signage)
- **Download system images** without sdkmanager or Java

### 🧾 Printer emulator

- A network thermal printer on **TCP 9100**, the standard raw printing port
- Answers common **ESC/POS status checks** and shows up in **network printer searches**, so your app sees it online
- Renders ESC/POS on 58 / 80 mm paper, including raster logos and signatures
- Copy a receipt as an **image** (paste into Jira) or text; view raw hex or the raw file of the last 30 receipts

### 🧹 Maintenance

- Clear the git package cache, **pub cache** and **Gradle cache**

### 🗂️ Work (Jira + Bitbucket)

- **My tickets**: what's assigned to you, grouped by status, with description, comments and status changes
- **Start work**: one click creates `feature/POS-123-…` (or `bugfix/…`) from `origin/develop`, moves the ticket to *In Progress* and opens VS Code
- **Push & create PR**: title and description from the ticket, default reviewers added, ticket moves to *Code Review*
- **Pull requests**: *To review* / *Mine* / *All* across your repos; **check out** a PR to test it on a device, **approve** from Flutter DevKit
- **Ticket in the workspace**: the device window shows the ticket of the branch you run; send a **screenshot** or **bug report** to it with one click
- Works with Jira Cloud (API token) and Server/Data Center (personal access token); tokens are encrypted for your Windows account, or kept in the Keychain on macOS

### 📝 Notes & history

- **Notes**: sticky notes for IPs, test steps, anything (<kbd>Ctrl</kbd>+<kbd>N</kbd>), with colors, pinning and search
- **History** for 30 days: activity, crashes with their log lines, full session logs

### 🧰 And more

- **Terminal** in the Editor's bottom panel, running in the open project with its pinned SDK on `PATH`
- **Multi Screen**: pick the devices you want in one window, with broadcast input
- Built-in **connection guide** for USB, Wireless debugging and the printer
- **Keeps running in the tray** when closed (quit from File or the tray icon)

## ⌨️ Workspace shortcuts

| Keys | Action |
| --- | --- |
| <kbd>F5</kbd> / <kbd>Shift</kbd>+<kbd>F5</kbd> | Flutter run again / stop |
| <kbd>Ctrl</kbd>+<kbd>F5</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F5</kbd> | Hot reload / hot restart |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> | Screenshot (copied) / save as… |
| <kbd>Ctrl</kbd>+<kbd>B</kbd> | Bug report (screenshot + log + info) |
| <kbd>Ctrl</kbd>+<kbd>I</kbd> | Install the latest build |
| <kbd>Ctrl</kbd>+<kbd>R</kbd> | Restart the focused app |
| <kbd>Ctrl</kbd>+<kbd>M</kbd> | Open remote (scrcpy) |
| <kbd>Ctrl</kbd>+<kbd>L</kbd> | Clear logcat |
| <kbd>Ctrl</kbd>+<kbd>1</kbd>…<kbd>7</kbd> | Switch tab |
| Click the screen | Type on the device with your keyboard (<kbd>Ctrl</kbd>+<kbd>V</kbd> pastes) |

## 🧭 First run

A short **Getting started** guide opens the first time you launch the app. It covers opening a project, writing code, running, debugging and committing. Bring it back from **Help → Getting started**.

To set up devices and the printer:

1. **Settings → Projects**: add the folder where you clone repos. Repos are matched by their Android `applicationId`, up to 3 levels deep, and become **My apps**. For apps you don't have cloned, add a package prefix in **Settings → Projects**.
2. **Devices**: if the orange **Network scan may miss devices** banner appears, click **Fix network access** once.
3. **Devices → Scan network**: phones with Wireless debugging show up. If one says **Needs pairing**, click its QR icon once.
4. **Printer**: in your app, set a network **ESC/POS** printer with this PC's IP, then print. On emulators like MEmu, use the PC IP (not `10.0.2.2`).

## 🛟 Troubleshooting

Uncaught errors are kept with their stack traces in `errors.log`. **Help → Show error log** opens its folder, which is useful to attach to a bug report.

| Problem | Try this |
| --- | --- |
| Device on another subnet isn't found | Add the subnet in **Settings → Devices** (`192.168.5`, `10.1.0.0/22`). The PC needs a route to it, and the device must be on port 5555: Wireless debugging discovery doesn't cross subnets. |
| Phone doesn't show up | Same Wi-Fi as the PC? Wireless debugging on? Click **Fix network access** on Devices (one admin prompt). |
| Tired of re-pairing | Device menu → **Enable port 5555**. Scans then find it on `ip:5555` until it reboots. |
| "Needs pairing" won't go away | Phone: **Wireless debugging → Pair device with pairing code**, then Flutter DevKit: **Pair device → Pairing code**. |
| `adb` keeps restarting | Another `adb` version is running (Android Studio, an old SDK). Keep just one on `PATH`. |
| Git packages stuck on an old commit | **Maintenance → Git packages cache → Clear**, then **Update core**. |
| Need an unmerged fix in a git package | **Maintenance →** click the package chip → **Git branch** or **Local folder**. |
| Work: Jira or Bitbucket won't connect | **Work → ⚙ → Test connection** shows the exact error. Bitbucket app passwords use your *username*, API tokens your *email*. |
| No ticket chip in the workspace | The branch name must contain the key (`feature/POS-123-…`) and the repo must be in **Settings → Projects**. |
| Source links don't open | Add the repo folder in **Settings → Projects** and run `pub get` once; VS Code's `code` must be on `PATH`. |

## 🛠️ Development

```sh
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

**Release build and installer** (needs [Inno Setup 6](https://jrsoftware.org/isinfo.php): `winget install JRSoftware.InnoSetup`):

```powershell
.\tool\build_installer.ps1             # release build + dist/DevKit-Setup.exe
.\tool\build_installer.ps1 -SkipBuild  # reuse the last release build
```

The version comes from `pubspec.yaml`.

> [!IMPORTANT]
> Building by hand? Keep `--no-tree-shake-icons` on `flutter build windows --release`, or some icons go missing.

<details>
<summary><b>Project layout</b></summary>

```text
lib/
  core/              themes, tools (adb/scrcpy lookup), tray, project scanning, source links
  modules/           what Flutter DevKit is built on
    editor/          Editor page, panels, Dart analysis server over LSP, debugger, Source Control
      engine/        our text editor: text model, multiple cursors, undo, syntax highlighting, rendering
    devices/         discovery, pairing, workspace window, multi screen
    console/         terminals (ConPTY + xterm)
    help/            connection guide
    settings/
  extensions/        built-in extensions, listed in registry.dart
    emulators/       AVD manager, system image downloads
    printer/         ESC/POS parser, TCP server, receipt view
    maintenance/     pub/Gradle cache cleanup, core packages, local overrides
    notes/           sticky notes
    work/            Jira + Bitbucket: tickets, branches, pull requests
    history/         activity, crashes, session logs
tool/
  build_installer.ps1     release build + installer
  make_icon.py            regenerates the app icon
  make_installer_art.py   regenerates the installer wizard images
windows/installer/        Inno Setup script and wizard images
windows/third_party/scrcpy/   bundled scrcpy + adb (Apache-2.0)
windows/runner/native_bridge.cpp, macos/Runner/MainFlutterWindow.swift   file drops
third_party/flutter_pty/      flutter_pty with Windows fixes for starting shells
```

New app? Put its repo in a project folder, and Flutter DevKit recognises it everywhere.

</details>

## 🧭 Roadmap: toward a Flutter IDE

Flutter DevKit already covers editing, running on devices, and package management. Next up:

- [ ] **Command palette** and go to symbol: <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd> and <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>O</kbd>
- [ ] **The same file in two views** of a split editor
- [ ] **Projects** as a top-level page: open a project, then see its devices, builds and git state
- [ ] **Widget inspector** in the debugger, over the VM service
- [ ] **More git in the editor**: blame, merge conflicts
- [ ] **Beyond Android, Windows and macOS**: iOS and Linux targets

## 📄 License

[MIT](LICENSE). The programs and packages it ships with stay under their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and in the app under **Help → About → View licenses**.

Flutter and Dart are trademarks of Google LLC, and Visual Studio Code is a trademark of Microsoft Corporation. This is an independent project, not affiliated with or endorsed by either.

---

<div align="center">
Made with 💚 for testing that's less tedious.
</div>
