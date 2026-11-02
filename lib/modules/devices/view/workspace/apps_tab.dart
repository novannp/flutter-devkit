import 'package:flutter/material.dart';

import '../../services/device_adb.dart';
import '../../../../core/mono_font.dart';

class AppsTab extends StatefulWidget {
  const AppsTab({super.key, required this.dev, required this.onInstall});

  final DeviceAdb dev;
  final VoidCallback onInstall;

  @override
  State<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<AppsTab> {
  List<String>? _packages;
  var _system = false;
  var _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await widget.dev.packages(thirdParty: !_system);
    if (!mounted) return;
    // Our apps always on top, ordered by knownApps.
    int rank(String p) {
      if (!isOurApp(p)) return 1000;
      final i = knownApps.indexWhere((a) => a.package == p);
      return i < 0 ? 999 : i;
    }

    list.sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : a.compareTo(b));
    setState(() => _packages = list);
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, width: 420));

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
          ],
        ),
      ) ==
      true;

  Future<void> _action(String pkg, String action) async {
    final dev = widget.dev;
    switch (action) {
      case 'launch':
        await dev.launch(pkg);
        _toast('Opening $pkg');
      case 'restart':
        await dev.forceStop(pkg);
        await dev.launch(pkg);
        _toast('Restarting $pkg');
      case 'prefs':
        final r = await dev.shell('run-as $pkg cat shared_prefs/FlutterSharedPreferences.xml');
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Shared prefs · ${appName(pkg)}'),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: SelectableText(
                  r.ok ? r.stdout : 'Failed (run-as only works on debug builds):\n${r.stderr}${r.stdout}',
                  style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5),
                ),
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          ),
        );
      case 'stop':
        await dev.forceStop(pkg);
        _toast('Force stop $pkg');
      case 'clear':
        if (!await _confirm('Clear data?', 'All $pkg data (login, cache, settings) will be erased.')) return;
        final r = await dev.clearData(pkg);
        _toast(r.stdout.contains('Success') ? '$pkg data cleared' : 'Failed: ${r.stdout}${r.stderr}');
      case 'uninstall':
        if (!await _confirm('Uninstall?', '$pkg will be removed from the device.')) return;
        final r = await dev.uninstall(pkg);
        _toast(r.stdout.contains('Success') ? '$pkg uninstalled' : 'Failed: ${r.stdout}${r.stderr}');
        _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final packages = _packages;
    final q = _query.toLowerCase();
    final visible = packages?.where((p) => p.toLowerCase().contains(q)).toList() ?? [];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Search packages…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Include system'),
                selected: _system,
                onSelected: (v) {
                  setState(() => _system = v);
                  _load();
                },
              ),
              const Spacer(),
              IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              FilledButton.icon(
                onPressed: widget.onInstall,
                icon: const Icon(Icons.install_mobile),
                label: const Text('Install APK…'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: packages == null
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (_, i) {
                    final pkg = visible[i];
                    final ours = isOurApp(pkg);
                    return ListTile(
                      leading: Icon(ours ? Icons.star : Icons.android, color: ours ? Colors.amber : null),
                      title: Text(ours ? appName(pkg) : pkg),
                      subtitle: ours ? Text(pkg) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Open',
                            icon: const Icon(Icons.play_arrow),
                            onPressed: () => _action(pkg, 'launch'),
                          ),
                          IconButton(
                            tooltip: 'Restart app',
                            icon: const Icon(Icons.replay),
                            onPressed: () => _action(pkg, 'restart'),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (a) => _action(pkg, a),
                            itemBuilder: (_) => [
                              if (ours) const PopupMenuItem(height: 30, value: 'prefs', child: Text('View shared prefs')),
                              const PopupMenuItem(height: 30, value: 'stop', child: Text('Force stop')),
                              const PopupMenuItem(height: 30, value: 'clear', child: Text('Clear data')),
                              const PopupMenuItem(height: 30, value: 'uninstall', child: Text('Uninstall')),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
