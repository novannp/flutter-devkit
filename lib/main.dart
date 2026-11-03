import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'modules/devices/services/flutter_hub.dart';
import 'core/windows.dart';
import 'core/licenses.dart';
import 'core/settings.dart';
import 'modules/settings/apply_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/background.dart';
import 'core/apps.dart';
import 'core/child_processes.dart';
import 'core/error_log.dart';
import 'core/theme.dart';
import 'core/tools.dart';
import 'modules/devices/cubit/devices_cubit.dart';
import 'modules/devices/models/device.dart';
import 'modules/devices/services/adb_service.dart';
import 'modules/devices/services/device_store.dart';
import 'modules/devices/services/mdns_service.dart';
import 'modules/devices/services/network_scanner.dart';
import 'modules/devices/view/workspace/workspace_page.dart';
import 'extensions/emulators/avd_service.dart';
import 'extensions/printer/printer_page.dart';
import 'extensions/registry.dart';
import 'shell.dart';
import 'core/history.dart';
import 'core/login_path.dart';

/// Workspace window argument: `--workspace=<device json>`; see [openWorkspaceWindow].
const workspaceArg = '--workspace=';

Future<void> main(List<String> args) async {
  await adoptLoginShellPath();
  WidgetsFlutterBinding.ensureInitialized();
  await installErrorLog();
  final tools = await Tools.resolve();
  // A slow network drive in the project folders shouldn't hold up launch; the list still fills in when it finishes.
  await loadApps().timeout(const Duration(seconds: 3), onTimeout: () {});
  await loadAppTheme();
  final prefs = await SharedPreferences.getInstance();
  await Settings.instance.load(seed: () => legacySettings(prefs));
  await AvdService.loadCustomSdk();
  final ws = args.where((a) => a.startsWith(workspaceArg)).firstOrNull;
  final device = ws == null
      ? null
      : Device.fromJson(
          jsonDecode(utf8.decode(base64Url.decode(ws.substring(workspaceArg.length)))) as Map<String, dynamic>,
        );
  // Only the main window hosts the printer; workspace windows would fight over the port.
  unawaited(ChildProcesses.killOrphans());
  if (device == null) unawaited(History.prune());
  startupProject = startupProjectOf(args);
  if (device != null) await BackgroundRunner.instance.initDeviceWindow();
  if (device == null) {
    await ExtensionManager.instance.load();
    // One printer for the computer: a second project window would fight over the port.
    if (startupProject == null && ExtensionManager.instance.isEnabled('printer')) unawaited(printerServer.init());
    await BackgroundRunner.instance.init();
    await FlutterHub.instance.start();
  }
  registerBundledLicenses();
  applySettings();
  Settings.instance
    ..addListener(applySettings)
    ..watch();
  runApp(HotRestartApp(tools: tools, workspace: device));
}

class HotRestartApp extends StatelessWidget {
  const HotRestartApp({super.key, required this.tools, this.workspace});

  final Tools tools;

  /// When set, this window is a single-device workspace.
  final Device? workspace;

  @override
  Widget build(BuildContext context) {
    final ws = workspace;
    return RepositoryProvider.value(
      value: AdbService(tools),
      child: Builder(
        builder: (context) => MultiBlocProvider(
          providers: [
            if (ws == null)
              BlocProvider(
                create: (_) {
                  final cubit = DevicesCubit(
                    adb: context.read<AdbService>(),
                    mdns: MdnsService(),
                    scanner: NetworkScanner(),
                    store: DeviceStore(),
                  )..init();
                  // HOTRESTART_DEMO=1 shows sample devices (README screenshots, demos).
                  if (Platform.environment['HOTRESTART_DEMO'] == '1') cubit.toggleDemo();
                  return cubit;
                },
              ),
          ],
          child: ValueListenableBuilder(
            valueListenable: appTheme,
            builder: (_, theme, _) => MaterialApp(
              title: ws == null ? 'HotRestart' : ws.displayName,
              debugShowCheckedModeBanner: false,
              theme: buildTheme(theme),
              builder: snackBarsBottomRight,
              home: ws == null ? const Shell() : DeviceWorkspacePage(device: ws, standalone: true),
            ),
          ),
        ),
      ),
    );
  }
}
