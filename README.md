<div align="center">

<img src="docs/logo.png" width="112" alt="DevKit logo" />

# DevKit

**The Flutter workbench: one window for your code, devices, logs and builds.**

Edit code, find devices, mirror them, read logs, hot reload, and fake printers, all without leaving one window.

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-desktop-02569B?logo=flutter&logoColor=white)
![scrcpy](https://img.shields.io/badge/scrcpy-3.3.4%20bundled-10B981)
![No setup](https://img.shields.io/badge/adb%20%26%20scrcpy-included-34D399)

[Install](#-install) · [Features](#-features) · [Shortcuts](#%EF%B8%8F-workspace-shortcuts) · [First run](#-first-run) · [Troubleshooting](#-troubleshooting) · [Development](#%EF%B8%8F-development)

<img src="docs/screenshot.png" width="860" alt="DevKit devices screen" />

</div>

---

## 🚀 Install

1. Download **[`dist/DevKit-Setup.exe`](dist/DevKit-Setup.exe)** and run it.
2. That's it. No admin rights needed, and `adb` + `scrcpy` are already inside.

To upgrade, run the newer setup over the old one. DevKit is closed for you, and settings from builds with the previous name carry over.

> [!NOTE]
> The installer isn't code-signed yet, so Windows may show **"Windows protected your PC"**. Click **More info → Run anyway**. Copying it from a shared folder instead of downloading usually avoids the prompt.

## 💡 Why you'll love it

Testing Flutter apps on real devices used to mean: check the IP in Settings, `adb connect`, open scrcpy, another terminal for logcat, another for `flutter run`, then hunt for a real printer. DevKit does all of it in one window:

- ✍️ **Edits your code** with full Dart analysis, using the SDK your project pins with fvm
- 🔍 **Finds every device** on your network, across subnets: USB, Wi-Fi 5555, and Wireless debugging
- 🖥️ **Mirrors and controls** devices at 60 fps, one by one or side by side
- 🔥 **Flutter run, hot reload, hot restart** next to the live screen and logcat
- 🧾 **Prints receipts without a printer**, straight on screen
- 👥 **Shows who's using which tablet** across the team
- 🗂️ **Jira ticket → branch → PR** without leaving DevKit

## ✨ Features

### ✍️ Editor

A native code editor with no WebView. The Dart analysis server starts only when you open a Dart file, and analyzes only the projects you have open.

- **Follows fvm**: analysis, `flutter` commands and the built-in terminal all use the SDK in `.fvm` / `.fvmrc`; projects without fvm use the one on `PATH`
- **Language features**: completion with auto-import, errors and warnings as you type, hover docs, go to definition, find references, rename, quick fixes
- **Flutter**: run on a connected device or Windows, hot reload on save, hot restart, `pub get` and friends; output lines with a `lib/…:line` open that spot
- **Editing**: tabs, syntax highlighting (Dart, YAML, JSON, XML, Kotlin, Gradle, Swift and more), code folding, find and replace, format on save, undo
- **Project**: file tree with create/rename/delete, quick open, search in files, problems panel, terminal
- **Debugger**: breakpoints in the gutter, step over/into/out, call stack, variables you can expand, evaluate in a frame, pause on exceptions. It connects by itself when you press Run, on a device or on Windows
- **Source Control**: changed files, stage and unstage, commit, push and pull, switch or create branches, discard, a diff panel, and gutter marks for lines that differ from `HEAD`
- Tabs follow changes on disk, such as a branch switch; unsaved edits are never overwritten

| Keys | Action |
| --- | --- |
| <kbd>Ctrl</kbd>+<kbd>S</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>S</kbd> | Save / save all |
| <kbd>Ctrl</kbd>+<kbd>P</kbd> / <kbd>Ctrl</kbd>+<kbd>G</kbd> | Quick open / go to line |
| <kbd>Ctrl</kbd>+<kbd>F</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F</kbd> | Find / search in files |
| <kbd>Ctrl</kbd>+<kbd>Space</kbd> / <kbd>F1</kbd> | Completion / show docs |
| <kbd>F12</kbd> or <kbd>Ctrl</kbd>+click / <kbd>Shift</kbd>+<kbd>F12</kbd> | Go to definition / find references |
| <kbd>F2</kbd> / <kbd>Ctrl</kbd>+<kbd>.</kbd> / <kbd>Shift</kbd>+<kbd>Alt</kbd>+<kbd>F</kbd> | Rename / quick fix / format |
| <kbd>F5</kbd> / <kbd>Shift</kbd>+<kbd>F5</kbd> | Run / stop |
| <kbd>Ctrl</kbd>+<kbd>F5</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F5</kbd> | Hot reload / hot restart |
| <kbd>F9</kbd> / <kbd>F6</kbd> | Toggle breakpoint / pause (<kbd>F5</kbd> continues) |
| <kbd>F10</kbd> / <kbd>F11</kbd> / <kbd>Shift</kbd>+<kbd>F11</kbd> | Step over / into / out |
| <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>G</kbd> | Source Control |
| <kbd>Ctrl</kbd>+<kbd>J</kbd> / <kbd>Ctrl</kbd>+<kbd>`</kbd> | Toggle panel / terminal |

### 📡 Devices

- **Auto-discovery** over USB, `adb` Wi-Fi (5555), and Wireless debugging (mDNS)
- **Pair** by QR, pairing code, or IP; **skip pairing** by plugging in USB once and tapping *Always allow*
- **Auto-switch to port 5555** so devices reconnect over Wi-Fi without pairing until reboot
- Shows which of **your apps and versions** are installed (detected from your project folders)
- **Scan across subnets**: add other subnets in **Settings → Network scan**; subnets of devices seen before are included automatically
- **In use by**: see who on the LAN has a device open, on their USB, or marked *I'm using this*
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
- Answers **Epson** and **Star** status checks and shows up in the **SNBC printer search**, so your app sees it online
- Renders ESC/POS on 58 / 80 mm paper, including SNBC raster logos and signatures
- Copy a receipt as an **image** (paste into Jira) or text; view raw hex or the raw file of the last 30 receipts

### 🧹 Maintenance

- **Switch the branch of any git package** in a project's `pubspec.yaml` or use a local clone, then `pub upgrade` runs
- **Override any package with a local path** (⋮ menu); active overrides show as orange chips, ✕ removes one
- Overrides go to `pubspec_overrides.yaml`, so `pubspec.yaml` stays untouched
- One-click **update git packages**; `pub get`, `pub upgrade`, `flutter clean` with live output
- Clear the git package cache, **pub cache** and **Gradle cache**

### 🗂️ Work (Jira + Bitbucket)

- **My tickets**: what's assigned to you, grouped by status, with description, comments and status changes
- **Start work**: one click creates `feature/POS-123-…` (or `bugfix/…`) from `origin/develop`, moves the ticket to *In Progress* and opens VS Code
- **Push & create PR**: title and description from the ticket, default reviewers added, ticket moves to *Code Review*
- **Pull requests**: *To review* / *Mine* / *All* across your repos; **check out** a PR to test it on a device, **approve** from DevKit
- **Ticket in the workspace**: the device window shows the ticket of the branch you run; send a **screenshot** or **bug report** to it with one click
- Works with Jira Cloud (API token) and Server/Data Center (personal access token); tokens are encrypted for your Windows account

### 💬 Team & notes

- **LAN chat** with no internet or server: Everyone channel, direct messages, Windows notifications
- **Notes**: sticky notes for IPs, test steps, anything (<kbd>Ctrl</kbd>+<kbd>N</kbd>), with colors, pinning and search
- **History** for 30 days: activity, crashes with their log lines, full session logs

### 🧰 And more

- **Terminal** tabs (Git Bash / PowerShell / cmd) in any project folder
- **Multi Screen**: many devices in one window, with broadcast input
- Built-in **connection guide** for USB, Wireless debugging and the printer
- **Keeps running in the tray** when closed · light & dark theme

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

1. **Settings → Project folders**: add the folder where you clone repos. Repos are matched by their Android `applicationId`, up to 3 levels deep, and become **My apps**. For apps you don't have cloned, add a package prefix in **Settings → My apps**.
2. **Devices**: if the orange **Network scan may miss devices** banner appears, click **Fix network access** once.
3. **Devices → Scan network**: phones with Wireless debugging show up. If one says **Needs pairing**, click its QR icon once.
4. **Printer**: in your app, set a network printer (**SNBC over Wi-Fi** works best) with this PC's IP, then print. On emulators like MEmu, use the PC IP (not `10.0.2.2`).

## 🛟 Troubleshooting

| Problem | Try this |
| --- | --- |
| Device on another subnet isn't found | Add the subnet in **Settings → Network scan** (`192.168.5`, `10.1.0.0/22`). The PC needs a route to it, and the device must be on port 5555: Wireless debugging discovery doesn't cross subnets. |
| Phone doesn't show up | Same Wi-Fi as the PC? Wireless debugging on? Click **Fix network access** on Devices (one admin prompt). |
| Tired of re-pairing | Device menu → **Enable port 5555**. Scans then find it on `ip:5555` until it reboots. |
| "Needs pairing" won't go away | Phone: **Wireless debugging → Pair device with pairing code**, then DevKit: **Pair device → Pairing code**. |
| `adb` keeps restarting | Another `adb` version is running (Android Studio, an old SDK). Keep just one on `PATH`. |
| Git packages stuck on an old commit | **Maintenance → Git packages cache → Clear**, then **Update core**. |
| Need an unmerged fix in a git package | **Maintenance →** click the package chip → **Git branch** or **Local folder**. |
| Teammates missing in Chat / "In use by" | Same network? **Fix network access** (UDP 47232 + TCP 47231). Try **🤖 Test bot** in Chat to test alone. |
| Work: Jira or Bitbucket won't connect | **Work → ⚙ → Test connection** shows the exact error. Bitbucket app passwords use your *username*, API tokens your *email*. |
| No ticket chip in the workspace | The branch name must contain the key (`feature/POS-123-…`) and the repo must be in **Settings → Project folders**. |
| Source links don't open | Add the repo folder in **Settings → Project folders** and run `pub get` once; VS Code's `code` must be on `PATH`. |

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
  core/            theme, tools (adb/scrcpy lookup), tray, project scanning, source links
  modules/
    devices/       discovery, pairing, workspace window, multi screen
    editor/        code editor, file tree, Dart analysis server over LSP, fvm SDK lookup
    emulators/     AVD manager, system image downloads
    printer/       ESC/POS parser, TCP server, receipt view
    console/       embedded terminals (ConPTY + xterm)
    chat/          LAN chat (UDP discovery, TCP messages, notifications)
    maintenance/   pub/Gradle cache cleanup, core packages, local overrides
    notes/         sticky notes
    work/          Jira + Bitbucket: tickets, branches, pull requests
    history/       activity, crashes, session logs
    help/          connection guide
    settings/
tool/
  build_installer.ps1     release build + installer
  make_icon.py            regenerates the app icon
  make_installer_art.py   regenerates the installer wizard images
windows/installer/        Inno Setup script and wizard images
windows/third_party/scrcpy/   bundled scrcpy + adb (Apache-2.0)
```

New app? Put its repo in a project folder, and DevKit recognises it everywhere.

</details>

## 🧭 Roadmap: toward a Flutter IDE

DevKit already covers editing, running on devices, and package management. Next up:

- [ ] **Projects** as a top-level page: open a project, then see its devices, builds and git state
- [ ] **Widget inspector** in the debugger, over the VM service
- [ ] **More git in the editor**: blame, merge conflicts
- [ ] **Beyond Android and Windows**: iOS, macOS and Linux targets

---

<div align="center">
Made with 💚 for testing that's less tedious.
</div>
