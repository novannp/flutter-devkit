import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/devices_cubit.dart';
import '../../../core/apps.dart';
import '../models/device.dart';
import '../../../core/windows.dart';
import 'network_access_banner.dart';
import 'pair_dialog.dart';
import '../../../core/mono_font.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DevicesCubit, DevicesState>(
      builder: (context, state) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(state: state),
            if (!state.adbAvailable || !state.scrcpyAvailable)
              _ToolsWarning(state: state),
            if (!state.demo) const NetworkAccessBanner(),
            if (state.scanning) LinearProgressIndicator(value: state.scanProgress),
            const SizedBox(height: 6),
            Expanded(
              child: Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _TableHeader(),
                    const Divider(height: 1),
                    Expanded(
                      child: state.filtered.isEmpty
                          ? _Empty(state: state)
                          : ListView.separated(
                              itemCount: state.filtered.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (_, i) =>
                                  _DeviceRow(device: state.filtered[i]),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _openWorkspace(BuildContext context, Device d) {
  final state = context.read<DevicesCubit>().state;
  if (!state.adbAvailable) {
    return _toast(context, Future.value('adb not found in PATH'));
  }
  if (d.adbTarget == null) {
    return _toast(context, Future.value('Device IP unknown'));
  }
  openWorkspaceWindow(d);
  _toast(context, Future.value('Opening ${d.displayName} in a new window…'));
}

void _toast(BuildContext context, Future<String> message) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = await message;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text)),
    );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color, required this.icon});

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '$value $label',
    child: Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 3),
          Text(value, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    ),
  );
}

class _ToolsWarning extends StatelessWidget {
  const _ToolsWarning({required this.state});

  final DevicesState state;

  @override
  Widget build(BuildContext context) {
    final missing = [
      if (!state.adbAvailable) 'adb',
      if (!state.scrcpyAvailable) 'scrcpy',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: MaterialBanner(
        content: Text(
          '${missing.join(' & ')} not found. Some features may not work.',
        ),
        leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
        actions: const [SizedBox.shrink()],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.state});

  final DevicesState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<DevicesCubit>();
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    Widget action(String tooltip, IconData icon, VoidCallback? onPressed) => IconButton(
      tooltip: tooltip,
      iconSize: 17,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      onPressed: onPressed,
      icon: Icon(icon),
    );
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          const Text('Devices', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
          if (state.demo) ...[
            const SizedBox(width: 6),
            Text('Demo', style: TextStyle(fontSize: 12, color: scheme.primary)),
          ],
          _Stat(label: 'online', value: '${state.onlineCount}', color: const Color(0xFF10B981), icon: Icons.wifi_tethering),
          _Stat(label: 'connected with ADB', value: '${state.adbCount}', color: const Color(0xFF3B82F6), icon: Icons.usb),
          _Stat(label: 'offline', value: '${state.devices.length - state.onlineCount}', color: scheme.outline, icon: Icons.portable_wifi_off),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: TextField(
                  onChanged: cubit.search,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Search name, serial, IP, model…',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    prefixIcon: Icon(Icons.search, size: 16),
                    prefixIconConstraints: BoxConstraints.tightFor(width: 28, height: 28),
                  ),
                ),
              ),
            ),
          ),
          if (wide) ...[
            Text('Demo', style: TextStyle(fontSize: 12, color: scheme.outline)),
            Transform.scale(
              scale: .7,
              child: Switch(value: state.demo, onChanged: (_) => cubit.toggleDemo()),
            ),
          ],
          action('Pair device', Icons.qr_code_2, () => showPairDialog(context)),
          action(
            state.scanning ? 'Scanning ${(state.scanProgress * 100).round()}%' : 'Scan network',
            Icons.radar,
            state.scanning ? null : () => _toast(context, cubit.scanNetwork()),
          ),
          action('Connect all', Icons.link, () => _toast(context, cubit.connectAll())),
          action('Enable port 5555 on all connected devices\n(scans find them without pairing)', Icons.settings_ethernet, () => _toast(context, cubit.enablePort5555All())),
          action('Disconnect all (Wi-Fi)', Icons.link_off, () => _toast(context, cubit.disconnectAll())),
        ],
      ),
    );
  }
}

const _cols = [4, 3, 2, 3, 2, 2, 2];
const _actionsWidth = 112.0;

// Name, IP and ADB are what you need to find and reach a device; the rest gives way first.
bool _showsAllColumns(BuildContext context) => MediaQuery.sizeOf(context).width >= 860;

const _alwaysShown = {0, 2, 5};
const _rowButton = BoxConstraints.tightFor(width: 26, height: 26);

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.outline,
      fontWeight: FontWeight.w600,
    );
    const labels = ['Name', 'Model', 'IP', 'Apps', 'Env', 'ADB', 'Status'];
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            if (_showsAllColumns(context) || _alwaysShown.contains(i))
              Expanded(
                flex: _cols[i],
                child: Text(labels[i], style: style),
              ),
          const SizedBox(width: _actionsWidth),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final d = device;
    final cubit = context.read<DevicesCubit>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.outline);
    final all = _showsAllColumns(context);

    return InkWell(
      onTap: () => _openWorkspace(context, d),
      hoverColor: scheme.primary.withValues(alpha: .04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: 32,
          child: Row(
          children: [
            Expanded(
              flex: _cols[0],
              child: Row(
                children: [
                  Tooltip(
                    message: '${d.online ? 'Online' : 'Offline'}, ${d.ip == null ? 'on USB' : 'on the network'}',
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Icon(
                          d.ip == null ? Icons.usb : Icons.phone_android,
                          size: 16,
                          color: d.online ? scheme.primary : scheme.outline,
                        ),
                        Positioned(
                          right: -2,
                          bottom: -1,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: d.online ? const Color(0xFF10B981) : scheme.outlineVariant,
                              shape: BoxShape.circle,
                              border: Border.all(color: scheme.surface, width: 1.5),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Tooltip(
                      message: [d.displayName, ?d.serial].join('\n'),
                      waitDuration: const Duration(milliseconds: 600),
                      child: Text.rich(
                        TextSpan(
                          text: d.displayName,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          children: [
                            if (d.serial != null && d.serial != d.displayName)
                              TextSpan(text: '  ${d.serial}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400, color: scheme.outline)),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  _InUse(device: d),
                ],
              ),
            ),
            if (all) Expanded(
              flex: _cols[1],
              child: Text(
                d.model ?? '-',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            Expanded(
              flex: _cols[2],
              child: d.ip == null
                  ? Text('USB', style: muted)
                  : SelectableText(
                      d.ip!,
                      maxLines: 1,
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontFamilyFallback: monoFallback,
                        fontSize: 12,
                      ),
                    ),
            ),
            if (all) Expanded(
              flex: _cols[3],
              child: _AppsCell(apps: d.apps),
            ),
            if (all) Expanded(
              flex: _cols[4],
              child: Align(
                alignment: Alignment.centerLeft,
                child: _EnvChip(env: d.env),
              ),
            ),
            Expanded(
              flex: _cols[5],
              child: Align(
                alignment: Alignment.centerLeft,
                child: _AdbBadge(state: d.adb),
              ),
            ),
            if (all) Expanded(
              flex: _cols[6],
              child: Text(_status(d), maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
            ),
            SizedBox(
              width: _actionsWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: _rowButton,
                    tooltip: 'Copy IP',
                    icon: const Icon(Icons.copy, size: 16),
                    onPressed: d.ip == null
                        ? null
                        : () {
                            Clipboard.setData(
                              ClipboardData(text: d.adbTarget!),
                            );
                            _toast(
                              context,
                              Future.value('${d.adbTarget} copied'),
                            );
                          },
                  ),
                  if (d.adb == AdbState.unpaired)
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: _rowButton,
                      tooltip: 'Pair this device (wireless debugging)',
                      icon: const Icon(
                        Icons.qr_code_2,
                        size: 16,
                        color: Colors.deepOrange,
                      ),
                      onPressed: () => showPairDialog(context),
                    )
                  else if (d.adb == AdbState.connected ||
                      d.adb == AdbState.unauthorized)
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: _rowButton,
                      tooltip: d.ip == null
                          ? 'Connected via USB'
                          : 'Disconnect',
                      icon: const Icon(Icons.link_off, size: 16),
                      onPressed: d.ip == null
                          ? null
                          : () => _toast(context, cubit.disconnect(d)),
                    )
                  else
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: _rowButton,
                      tooltip: 'Connect',
                      icon: const Icon(Icons.link, size: 16),
                      onPressed: d.adbTarget == null
                          ? null
                          : () => _toast(context, cubit.connect(d)),
                    ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: _rowButton,
                    tooltip: 'Remote (scrcpy)',
                    icon: const Icon(Icons.cast, size: 16),
                    onPressed: () => _toast(context, cubit.remote(d)),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(minimumSize: const Size(26, 26), fixedSize: const Size(26, 26), padding: EdgeInsets.zero),
                    onSelected: (v) => switch (v) {
                      'connect' => _toast(context, cubit.connect(d)),
                      'disconnect' => _toast(context, cubit.disconnect(d)),
                      'tcpip' => _toast(context, cubit.enablePort5555(d)),
                      'rename' => _rename(context, d),
                      'claim' => cubit.toggleClaim(d),
                      'find' => _toast(context, cubit.find(d)),
                      'label' => _toast(context, cubit.labelWallpaper(d)),
                      'forget' => cubit.forget(d),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        height: 30,
                        value: 'connect',
                        child: Text('Connect ADB'),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'disconnect',
                        child: Text('Disconnect'),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'tcpip',
                        child: Text('Enable port 5555 (no pairing)'),
                      ),
                      CheckedPopupMenuItem(
                        height: 30,
                        value: 'claim',
                        checked: cubit.state.claimed.contains(d.id),
                        child: const Text("I'm using this"),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'find',
                        child: Text('Find (blink & vibrate)'),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'label',
                        child: Text('Set name label as wallpaper'),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      const PopupMenuItem(
                        height: 30,
                        value: 'forget',
                        child: Text('Remove from list'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  String _status(Device d) {
    if (d.online) return 'Online';
    final seen = d.lastSeen;
    if (seen == null) return 'Offline';
    final diff = DateTime.now().difference(seen);
    final ago = diff.inDays > 0
        ? '${diff.inDays}d'
        : diff.inHours > 0
        ? '${diff.inHours}h'
        : '${diff.inMinutes}m';
    return 'Offline · $ago ago';
  }

  Future<void> _rename(BuildContext context, Device d) async {
    final cubit = context.read<DevicesCubit>();
    final controller = TextEditingController(text: d.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'As on the sticker, e.g. T2-07',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) cubit.rename(d, name);
  }
}

/// "In use by You" when this PC has the device open, on USB, or marked as in use.
class _InUse extends StatelessWidget {
  const _InUse({required this.device});

  final Device device;

  static const _why = {
    'workspace': 'workspace open',
    'usb': 'on USB',
    'claimed': 'marked in use',
  };

  @override
  Widget build(BuildContext context) {
    final mine = context.read<DevicesCubit>().usageReason(device);
    if (mine == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: 'You · ${_why[mine]}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person, size: 13, color: color),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              'In use by You',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppsCell extends StatelessWidget {
  const _AppsCell({required this.apps});

  final Map<String, String> apps;

  @override
  Widget build(BuildContext context) {
    if (apps.isEmpty) return const Text('-');
    final scheme = Theme.of(context).colorScheme;
    final ordered = apps.entries.toList()
      ..sort((a, b) {
        int rank(String p) {
          final i = knownApps.indexWhere((k) => k.package == p);
          return i < 0 ? 99 : i;
        }

        return rank(a.key).compareTo(rank(b.key));
      });
    return Tooltip(
      message: ordered.map((e) => '${appName(e.key)}  ${e.value}').join('\n'),
      child: Row(
        children: [
          Flexible(child: _Pill(text: '${appShort(ordered.first.key)} ${ordered.first.value}', color: scheme.primary)),
          if (ordered.length > 1) ...[
            const SizedBox(width: 4),
            _Pill(text: '+${ordered.length - 1}', color: scheme.outline),
          ],
        ],
      ),
    );
  }
}

class _EnvChip extends StatelessWidget {
  const _EnvChip({required this.env});

  final String? env;

  @override
  Widget build(BuildContext context) {
    if (env == null) return const Text('-');
    final color = switch (env) {
      'prod' || 'production' => Colors.red,
      'qa' => Colors.teal,
      _ => Colors.grey,
    };
    return _Pill(
      text: env!.toLowerCase() == 'qa'
          ? 'QA'
          : (env!.startsWith('prod') ? 'Prod' : env!),
      color: color,
    );
  }
}

class _AdbBadge extends StatelessWidget {
  const _AdbBadge({required this.state});

  final AdbState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    AdbState.connected => const _Pill(text: 'Connected', color: Colors.blue),
    AdbState.unauthorized => const _Pill(
      text: 'Unauthorized',
      color: Colors.orange,
    ),
    AdbState.unpaired => const Tooltip(
      message:
          "This PC isn't trusted yet. Pair once, or plug in USB and tap 'Always allow' — "
          'after that Wi-Fi connects without pairing.',
      child: _Pill(text: 'Needs pairing', color: Colors.deepOrange),
    ),
    AdbState.offline => const _Pill(text: 'Offline', color: Colors.grey),
    AdbState.unknown => const Text('-'),
  };
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.state});

  final DevicesState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final searching = state.query.isNotEmpty;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            searching ? Icons.search_off : Icons.wifi_find,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            searching ? 'No matching devices' : 'No devices yet',
            style: text.titleMedium,
          ),
          if (!searching)
            const Text(
              'Click "Scan network", or turn on Demo to see examples.',
            ),
        ],
      ),
    );
  }
}
