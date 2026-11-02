import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


import '../../services/device_adb.dart';

const _sections = {
  'manufacturer': 'getprop ro.product.manufacturer',
  'model': 'getprop ro.product.model',
  'android': 'getprop ro.build.version.release',
  'sdk': 'getprop ro.build.version.sdk',
  'serial': 'getprop ro.serialno',
  'build': 'getprop ro.build.display.id',
  'size': 'wm size',
  'density': 'wm density',
  'battery': 'dumpsys battery',
  'storage': 'df -h /data | tail -1',
  'mem': 'cat /proc/meminfo | head -3',
  'uptime': 'cat /proc/uptime',
  'ip': 'ip -f inet addr show wlan0 | grep inet',
};

class InfoTab extends StatefulWidget {
  const InfoTab({super.key, required this.dev});

  final DeviceAdb dev;

  @override
  State<InfoTab> createState() => _InfoTabState();
}

class _InfoTabState extends State<InfoTab> {
  Map<String, String>? _raw;
  Map<String, String> _apps = const {};
  var _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    // Single `adb shell` call so it's fast over Wi-Fi.
    final script = _sections.entries.map((e) => 'echo "@@${e.key}"; ${e.value} 2>/dev/null').join('; ');
    final out = await widget.dev.sh(script);
    final raw = <String, String>{};
    String? key;
    final buf = StringBuffer();
    for (final line in out.split('\n')) {
      if (line.startsWith('@@')) {
        if (key != null) raw[key] = buf.toString().trim();
        key = line.substring(2).trim();
        buf.clear();
      } else {
        buf.writeln(line);
      }
    }
    if (key != null) raw[key] = buf.toString().trim();
    final apps = await widget.dev.ourApps();
    if (!mounted) return;
    setState(() {
      _raw = raw;
      _apps = apps;
      _loading = false;
    });
  }

  String? _field(String section, String name) {
    final m = RegExp('$name: (.+)').firstMatch(_raw?[section] ?? '');
    return m?[1]?.trim();
  }

  String _battery() {
    final level = _field('battery', 'level');
    if (level == null) return '-';
    final charging = ['AC powered', 'USB powered', 'Wireless powered'].any((k) => _field('battery', k) == 'true');
    final temp = int.tryParse(_field('battery', 'temperature') ?? '');
    return '$level%${charging ? ' · charging' : ''}${temp != null ? ' · ${(temp / 10).toStringAsFixed(1)}°C' : ''}';
  }

  String _memory() {
    int? kb(String k) => int.tryParse(RegExp('$k:\\s+(\\d+)').firstMatch(_raw?['mem'] ?? '')?[1] ?? '');
    final total = kb('MemTotal');
    final avail = kb('MemAvailable');
    if (total == null) return '-';
    String gb(int v) => '${(v / 1024 / 1024).toStringAsFixed(1)} GB';
    return avail == null ? gb(total) : '${gb(avail)} free / ${gb(total)}';
  }

  String _uptime() {
    final secs = double.tryParse((_raw?['uptime'] ?? '').split(' ').first);
    if (secs == null) return '-';
    final d = Duration(seconds: secs.round());
    return '${d.inDays}d ${d.inHours % 24}h ${d.inMinutes % 60}m';
  }

  String _storage() {
    final parts = (_raw?['storage'] ?? '').split(RegExp(r'\s+'));
    return parts.length >= 5 ? '${parts[3]} free / ${parts[1]} (${parts[4]} used)' : '-';
  }

  @override
  Widget build(BuildContext context) {
    final raw = _raw;
    if (raw == null) return const Center(child: CircularProgressIndicator());

    final size = raw['size']?.split('\n').last.split(':').last.trim();
    final density = raw['density']?.split('\n').last.split(':').last.trim();
    final ip = RegExp(r'inet (\S+)').firstMatch(raw['ip'] ?? '')?[1];

    final items = {
      'Model': '${raw['manufacturer']} ${raw['model']}',
      'Android': '${raw['android']} (SDK ${raw['sdk']})',
      'Serial': raw['serial'] ?? '-',
      'Wi-Fi IP': ip ?? '-',
      'Display': '${size ?? '-'} · ${density ?? '-'} dpi',
      'Battery': _battery(),
      'RAM': _memory(),
      'Storage': _storage(),
      'Uptime': _uptime(),
      'Build': raw['build'] ?? '-',
      'ADB target': widget.dev.target,
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Text('Device info', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (_loading) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final e in items.entries) _InfoCard(label: e.key, value: e.value)],
        ),
        const SizedBox(height: 24),
        Text('My apps', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_apps.isEmpty)
          const Text('None of your apps are installed. Add them in Settings → Projects.')
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final e in _apps.entries)
                _InfoCard(label: appName(e.key), value: e.value),
            ],
          ),
        const SizedBox(height: 24),
        Text('Actions', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => widget.dev.shell('am start -a android.settings.SETTINGS'),
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
            OutlinedButton.icon(
              onPressed: () => widget.dev.shell('am start -a android.settings.WIFI_SETTINGS'),
              icon: const Icon(Icons.wifi),
              label: const Text('Wi-Fi Settings'),
            ),
            OutlinedButton.icon(
              onPressed: () => widget.dev.shell('am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS'),
              icon: const Icon(Icons.developer_mode),
              label: const Text('Developer options'),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => _confirmReboot(context),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reboot'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmReboot(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reboot device?'),
        content: const Text('ADB Wi-Fi will disconnect until the device is back on.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reboot')),
        ],
      ),
    );
    if (ok == true) widget.dev.reboot();
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label copied'), behavior: SnackBarBehavior.floating, width: 300));
      },
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: scheme.outline, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
