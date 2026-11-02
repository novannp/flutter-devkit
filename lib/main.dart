import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'core/background.dart';
import 'core/apps.dart';
import 'core/child_processes.dart';
import 'core/legacy.dart';
import 'modules/chat/chat_notifier.dart';
import 'modules/chat/chat_service.dart';
import 'core/theme.dart';
import 'core/tools.dart';
import 'modules/devices/cubit/devices_cubit.dart';
import 'modules/devices/models/device.dart';
import 'modules/devices/services/adb_service.dart';
import 'modules/devices/services/device_store.dart';
import 'modules/devices/services/mdns_service.dart';
import 'modules/devices/services/network_scanner.dart';
import 'modules/devices/view/workspace/workspace_page.dart';
import 'modules/printer/printer_page.dart';
import 'shell.dart';
import 'core/history.dart';

/// Workspace window argument: `--workspace=<device json>`; see [openWorkspaceWindow].
const workspaceArg = '--workspace=';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before anything opens the preferences file.
  await migrateFromLegacyName();
  final tools = await Tools.resolve();
  // A slow network drive in the project folders shouldn't hold up launch; the list still fills in when it finishes.
  await loadApps().timeout(const Duration(seconds: 3), onTimeout: () {});
  await loadThemeMode();
  final ws = args.where((a) => a.startsWith(workspaceArg)).firstOrNull;
  final device = ws == null
      ? null
      : Device.fromJson(
          jsonDecode(utf8.decode(base64Url.decode(ws.substring(workspaceArg.length)))) as Map<String, dynamic>,
        );
  // Only the main window hosts the printer; workspace windows would fight over the port.
  unawaited(ChildProcesses.killOrphans());
  if (device == null) unawaited(History.prune());
  if (device == null) {
    unawaited(printerServer.init());
    await BackgroundRunner.instance.init();
    await ChatNotifier.setup();
    await ChatService.instance.start();
  }
  runApp(DevKitApp(tools: tools, workspace: device));
}

class DevKitApp extends StatelessWidget {
  const DevKitApp({super.key, required this.tools, this.workspace});

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
                  // DEVKIT_DEMO=1 shows sample devices (README screenshots, demos).
                  if (Platform.environment['DEVKIT_DEMO'] == '1') cubit.toggleDemo();
                  return cubit;
                },
              ),
          ],
          child: ValueListenableBuilder(
            valueListenable: themeMode,
            builder: (_, mode, _) => MaterialApp(
              title: ws == null ? 'DevKit' : ws.displayName,
              debugShowCheckedModeBanner: false,
              theme: buildTheme(Brightness.light),
              darkTheme: buildTheme(Brightness.dark),
              themeMode: mode,
              home: ws == null ? const Shell() : DeviceWorkspacePage(device: ws, standalone: true),
            ),
          ),
        ),
      ),
    );
  }
}
