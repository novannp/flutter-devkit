import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/devices_cubit.dart';
import '../../../core/apps.dart';
import '../models/device.dart';
import '../../../core/windows.dart';
import '../../chat/chat_service.dart';
import 'network_access_banner.dart';
import 'pair_dialog.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DevicesCubit, DevicesState>(
      builder: (context, state) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(state: state),
            if (!state.adbAvailable || !state.scrcpyAvailable) _ToolsWarning(state: state),
            if (!state.demo) const NetworkAccessBanner(),
            const SizedBox(height: 16),
            _Toolbar(state: state),
            if (state.scanning) ...[const SizedBox(height: 8), LinearProgressIndicator(value: state.scanProgress)],
            const SizedBox(height: 14),
            Expanded(
              child: Card(
                margin: const EdgeInsets.only(bottom: 20),
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
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: 16, endIndent: 16),
                              itemBuilder: (_, i) => _DeviceRow(device: state.filtered[i]),
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
  if (!state.adbAvailable) return _toast(context, Future.value('adb not found in PATH'));
  if (d.adbTarget == null) return _toast(context, Future.value('Device IP unknown'));
  openWorkspaceWindow(d);
  final users = ChatService.instance.usersOf(serial: d.serial, ip: d.ip).map((u) => u.$1.name).toSet();
  _toast(
    context,
    Future.value(
      users.isEmpty
          ? 'Opening ${d.displayName} in a new window…'
          : 'Heads up: ${users.join(', ')} ${users.length == 1 ? 'is' : 'are'} using ${d.displayName}',
    ),
  );
}

void _toast(BuildContext context, Future<String> message) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = await message;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, width: 420));
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final DevicesState state;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final total = state.devices.length;
    return Row(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Devices', style: text.headlineSmall),
            Text(
              'Android devices on USB and your network',
              style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
        if (state.demo) ...[
          const SizedBox(width: 12),
          const Chip(label: Text('DEMO'), visualDensity: VisualDensity.compact),
        ],
        const Spacer(),
        _Stat(
          label: 'Online',
          value: '${state.onlineCount}',
          color: const Color(0xFF10B981),
          icon: Icons.wifi_tethering,
        ),
        _Stat(label: 'ADB', value: '${state.adbCount}', color: const Color(0xFF3B82F6), icon: Icons.usb),
        _Stat(
          label: 'Offline',
          value: '${total - state.onlineCount}',
          color: Theme.of(context).colorScheme.outline,
          icon: Icons.portable_wifi_off,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.color, required this.icon});

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(left: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17, height: 1.1)),
              Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolsWarning extends StatelessWidget {
  const _ToolsWarning({required this.state});

  final DevicesState state;

  @override
  Widget build(BuildContext context) {
    final missing = [if (!state.adbAvailable) 'adb', if (!state.scrcpyAvailable) 'scrcpy'];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: MaterialBanner(
        content: Text('${missing.join(' & ')} not found. Some features may not work.'),
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
    return Row(
      children: [
        SizedBox(
          width: 360,
          child: TextField(
            onChanged: cubit.search,
            decoration: const InputDecoration(
              hintText: 'Search name, serial, IP, model…',
              prefixIcon: Icon(Icons.search, size: 20),
            ),
          ),
        ),
        const Spacer(),
        Row(
          children: [
            Text('Demo', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
            Transform.scale(
              scale: .8,
              child: Switch(value: state.demo, onChanged: (_) => cubit.toggleDemo()),
            ),
          ],
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: () => showPairDialog(context),
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Pair device'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: state.scanning ? null : () => _toast(context, cubit.scanNetwork()),
          icon: const Icon(Icons.radar),
          label: Text(state.scanning ? 'Scanning ${(state.scanProgress * 100).round()}%' : 'Scan network'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () => _toast(context, cubit.connectAll()),
          icon: const Icon(Icons.link),
          label: const Text('Connect all'),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: 'Enable port 5555 on all connected devices\n(scans find them without pairing until they reboot)',
          style: IconButton.styleFrom(side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
          onPressed: () => _toast(context, cubit.enablePort5555All()),
          icon: const Icon(Icons.settings_ethernet, size: 20),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: 'Disconnect all (Wi-Fi)',
          style: IconButton.styleFrom(side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
          onPressed: () => _toast(context, cubit.disconnectAll()),
          icon: const Icon(Icons.link_off, size: 20),
        ),
      ],
    );
  }
}

const _cols = [4, 3, 2, 3, 2, 2, 2];
const _actionsWidth = 190.0;

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: scheme.outline, fontWeight: FontWeight.w600, letterSpacing: .6);
    const labels = ['NAME', 'MODEL', 'IP', 'APPS', 'ENV', 'ADB', 'STATUS'];
    return Container(
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
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

    return InkWell(
      onTap: () => _openWorkspace(context, d),
      hoverColor: scheme.primary.withValues(alpha: .04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              flex: _cols[0],
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          d.ip == null ? Icons.usb : Icons.phone_android,
                          size: 20,
                          color: d.online ? scheme.primary : scheme.outline,
                        ),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 11,
                          height: 11,
                          decoration: BoxDecoration(
                            color: d.online ? const Color(0xFF10B981) : scheme.outlineVariant,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: d.displayName,
                          waitDuration: const Duration(milliseconds: 600),
                          child: Text(
                            d.displayName,
                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (d.serial != null)
                          Text(d.serial!, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                        _InUse(device: d),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: _cols[1],
              child: Text(d.model ?? '-', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            ),
            Expanded(
              flex: _cols[2],
              child: d.ip == null
                  ? Text('USB', style: muted)
                  : SelectableText(d.ip!, style: const TextStyle(fontFamily: 'Consolas', fontSize: 13)),
            ),
            Expanded(
              flex: _cols[3],
              child: _AppsCell(apps: d.apps),
            ),
            Expanded(
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
            Expanded(
              flex: _cols[6],
              child: Text(_status(d), style: muted),
            ),
            SizedBox(
              width: _actionsWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Copy IP',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: d.ip == null
                        ? null
                        : () {
                            Clipboard.setData(ClipboardData(text: d.adbTarget!));
                            _toast(context, Future.value('${d.adbTarget} copied'));
                          },
                  ),
                  if (d.adb == AdbState.unpaired)
                    IconButton(
                      tooltip: 'Pair this device (wireless debugging)',
                      icon: const Icon(Icons.qr_code_2, size: 18, color: Colors.deepOrange),
                      onPressed: () => showPairDialog(context),
                    )
                  else if (d.adb == AdbState.connected || d.adb == AdbState.unauthorized)
                    IconButton(
                      tooltip: d.ip == null ? 'Connected via USB' : 'Disconnect',
                      icon: const Icon(Icons.link_off, size: 18),
                      onPressed: d.ip == null ? null : () => _toast(context, cubit.disconnect(d)),
                    )
                  else
                    IconButton(
                      tooltip: 'Connect',
                      icon: const Icon(Icons.link, size: 18),
                      onPressed: d.adbTarget == null ? null : () => _toast(context, cubit.connect(d)),
                    ),
                  IconButton(
                    tooltip: 'Remote (scrcpy)',
                    icon: const Icon(Icons.cast, size: 18),
                    onPressed: () => _toast(context, cubit.remote(d)),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
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
                      const PopupMenuItem(value: 'connect', child: Text('Connect ADB')),
                      const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
                      const PopupMenuItem(value: 'tcpip', child: Text('Enable port 5555 (no pairing)')),
                      CheckedPopupMenuItem(
                        value: 'claim',
                        checked: cubit.state.claimed.contains(d.id),
                        child: const Text("I'm using this"),
                      ),
                      const PopupMenuItem(value: 'find', child: Text('Find (blink & vibrate)')),
                      const PopupMenuItem(value: 'label', child: Text('Set name label as wallpaper')),
                      const PopupMenuItem(value: 'rename', child: Text('Rename')),
                      const PopupMenuItem(value: 'forget', child: Text('Remove from list')),
                    ],
                  ),
                ],
              ),
            ),
          ],
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
          decoration: const InputDecoration(hintText: 'As on the sticker, e.g. T2-07'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name != null) cubit.rename(d, name);
  }
}

/// "In use by …" from teammates' DevKits on the LAN, or "You" when this PC is using it.
class _InUse extends StatelessWidget {
  const _InUse({required this.device});

  final Device device;

  static const _why = {'workspace': 'workspace open', 'usb': 'on USB', 'claimed': 'marked in use'};

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ChatService.instance,
    builder: (context, _) {
      final mine = context.read<DevicesCubit>().usageReason(device);
      final others = ChatService.instance.usersOf(serial: device.serial, ip: device.ip);
      if (mine == null && others.isEmpty) return const SizedBox.shrink();
      final names = [if (mine != null) 'You', ...others.map((u) => u.$1.name).toSet()];
      final details = [
        if (mine != null) 'You · ${_why[mine]}',
        for (final (peer, why) in others) '${peer.name} (${peer.host}) · ${_why[why] ?? why}',
      ];
      final color = others.isEmpty ? Theme.of(context).colorScheme.primary : const Color(0xFFF59E0B);
      return Tooltip(
        message: details.join('\n'),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person, size: 13, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                'In use by ${names.join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    },
  );
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
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in ordered.take(2)) _Pill(text: '${appShort(e.key)} ${e.value}', color: scheme.primary),
          if (ordered.length > 2) _Pill(text: '+${ordered.length - 2}', color: scheme.outline),
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
    return _Pill(text: env!.toLowerCase() == 'qa' ? 'QA' : (env!.startsWith('prod') ? 'Prod' : env!), color: color);
  }
}

class _AdbBadge extends StatelessWidget {
  const _AdbBadge({required this.state});

  final AdbState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    AdbState.connected => const _Pill(text: 'Connected', color: Colors.blue),
    AdbState.unauthorized => const _Pill(text: 'Unauthorized', color: Colors.orange),
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.fade,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
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
          Icon(searching ? Icons.search_off : Icons.wifi_find, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(searching ? 'No matching devices' : 'No devices yet', style: text.titleMedium),
          if (!searching) const Text('Click "Scan network", or turn on Demo to see examples.'),
        ],
      ),
    );
  }
}
