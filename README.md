# Ravo DevKit

All-in-one Windows desktop toolkit for testing Ravo / Rova apps on Android devices: find devices on the office network, mirror and control them, read logs, run Flutter, emulate printers and payment terminals.

## Features

| Menu | What it does |
| --- | --- |
| **Devices** | Lists devices from USB, `adb` over Wi-Fi (port 5555), Android 11+ Wireless debugging (mDNS) and our apps' `_ravodev._tcp` broadcast. Scan network, pair (QR, pairing code with IP + port, or connect by IP), connect/disconnect, copy IP. Click a device to open its workspace in a new window. |
| **Device workspace** | Screen mirror (fast: embedded scrcpy, lite: screenshots), logcat with crash detection, Flutter run/attach with hot reload/restart, shell, files, apps, device info, developer toggles, and a display editor (resolution, DPI, screen-size presets from phones to 21.5" POS and 43" signage). |
| **Multi Screen** | Several device screens in one window, with broadcast input. |
| **Emulators** | AVD manager: start, cold boot, headless, stop, wipe data, edit hardware, delete, open workspace. Create AVDs from size presets. **System images**: browse Google's catalog, download/remove images (no Android Studio, sdkmanager or Java needed). |
| **Printer** | ESC/POS network printer emulator on TCP 9100: shows receipts on 58/80 mm paper, copy as image/text, raw hex view. |
| **Store Codes** | Activation and support codes per store. |
| **Terminals** | Scans the subnet for PAX terminals (POSLink, default port 10009) and identifies model/serial with a read-only `A00` command. |
| **Maintenance** | Per-project `pub get`, update core packages (`pos_core`, `pf_processor_plugin`), `flutter clean`; clear the core-package git cache, pub cache, Gradle cache; manage system images. |
| **Settings** | Project folders (each developer's repo location), tool paths. |
| **Guide** | In-app guide for connecting USB, Wireless debugging, legacy `adb tcpip`, and the printer emulator. |

## Requirements

- Windows 10/11 x64
- [FVM](https://fvm.app/) (the Flutter version is pinned in `.fvmrc`)
- Android SDK with the emulator, only for the **Emulators** menu (installed with Android Studio)

`scrcpy` 3.3.4 and `adb` ship with the app (`windows/third_party/scrcpy`), so nothing else needs installing. If `adb` is already on your `PATH`, DevKit uses that one so the two don't fight over the adb server.

## Build & run

```sh
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

Release build:

```sh
fvm flutter build windows --release --no-tree-shake-icons
```

The output is in `build/windows/x64/runner/Release/`. Zip that whole folder to share it. Use `--no-tree-shake-icons`, because some Material icons go missing in release builds without it.

## First-time setup

1. **Settings → Project folders**: add the folder where you clone repos. Repos are detected by their Android `applicationId`, so folder names don't matter. Repos are found up to 3 levels deep.
2. **Devices → Scan network** finds devices on port 5555 and those with Wireless debugging on. If a device shows **Needs pairing**, use **Pair device** once.
3. **Printer**: point the POS printer setting at this PC's IP and port 9100.

## Project layout

```
lib/
  core/            theme, tools (adb/scrcpy lookup), project scanning, shared helpers
  modules/
    devices/       device list, discovery, pairing, workspace window, multi screen
    emulators/     AVD manager and system image downloads
    printer/       ESC/POS parser, TCP server, receipt view
    terminal/      PAX POSLink scanner
    maintenance/   pub/gradle cache cleanup, core package updates
    stores/        store activation/support codes
    help/          connection guide
    settings/
windows/third_party/scrcpy/   bundled scrcpy + adb (Apache-2.0)
```

New apps only need to be added to `knownApps` in `lib/core/apps.dart`.
