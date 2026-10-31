import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/local_builds.dart';
import '../devices/services/network_scanner.dart';
import 'pax_service.dart';

class PaxTerminal {
  PaxTerminal({
    required this.ip,
    required this.port,
    this.name,
    this.model,
    this.serial,
    this.os,
    this.mode,
    DateTime? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now();

  final String ip;
  final int port;
  String? name;
  String? model;
  String? serial;
  String? os;
  String? mode;
  DateTime lastSeen;
  bool online = true;
  bool identifying = false;

  String get title => name ?? model ?? 'PAX terminal';

  Map<String, dynamic> toJson() => {
    'ip': ip,
    'port': port,
    'name': name,
    'model': model,
    'serial': serial,
    'os': os,
    'mode': mode,
    'lastSeen': lastSeen.toIso8601String(),
  };

  factory PaxTerminal.fromJson(Map<String, dynamic> j) => PaxTerminal(
    ip: j['ip'] as String,
    port: j['port'] as int,
    name: j['name'] as String?,
    model: j['model'] as String?,
    serial: j['serial'] as String?,
    os: j['os'] as String?,
    mode: j['mode'] as String?,
    lastSeen: DateTime.tryParse(j['lastSeen'] as String? ?? ''),
  )..online = false;
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  static const _prefKey = 'pax_terminals';
  static const _prefPort = 'pax_port';

  final _scanner = NetworkScanner();
  final _pax = PaxService();
  final _terminals = <PaxTerminal>[];
  late final _portCtrl = TextEditingController(text: '${PaxService.defaultPort}');
  double? _progress;

  int get _port => int.tryParse(_portCtrl.text) ?? PaxService.defaultPort;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    _portCtrl.text = '${prefs.getInt(_prefPort) ?? PaxService.defaultPort}';
    if (raw == null || !mounted) return;
    setState(
      () => _terminals
        ..clear()
        ..addAll([for (final j in jsonDecode(raw) as List) PaxTerminal.fromJson(j as Map<String, dynamic>)]),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode([for (final t in _terminals) t.toJson()]));
    await prefs.setInt(_prefPort, _port);
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), width: 420));

  Future<void> _scan() async {
    final port = _port;
    setState(() {
      _progress = 0;
      for (final t in _terminals) {
        t.online = false;
      }
    });
    var found = 0;
    await for (final ip in _scanner.scan(
      port,
      timeout: const Duration(milliseconds: 600),
      onProgress: (d, t) {
        if (mounted) setState(() => _progress = d / t);
      },
    )) {
      found++;
      final existing = _terminals.where((t) => t.ip == ip && t.port == port).firstOrNull;
      setState(() {
        if (existing != null) {
          existing
            ..online = true
            ..lastSeen = DateTime.now();
        } else {
          _terminals.add(PaxTerminal(ip: ip, port: port));
        }
      });
    }
    if (!mounted) return;
    setState(() => _progress = null);
    await _save();
    _toast(found == 0 ? 'No terminals found on port $port' : 'Found $found terminal(s) on port $port');
  }

  Future<void> _identify(PaxTerminal t) async {
    setState(() => t.identifying = true);
    final info = await _pax.identify(t.ip, port: t.port);
    if (!mounted) return;
    setState(() {
      t.identifying = false;
      if (info != null) {
        t
          ..model = info.model ?? t.model
          ..serial = info.serial ?? t.serial
          ..os = info.os ?? t.os
          ..mode = info.mode
          ..online = true
          ..lastSeen = DateTime.now();
      }
    });
    if (info == null) _toast('${t.ip} didn\'t answer POSLink — it may be busy or not a PAX terminal');
    await _save();
  }

  Future<void> _identifyAll() async {
    for (final t in _terminals.where((t) => t.online).toList()) {
      await _identify(t);
    }
  }

  Future<void> _rename(PaxTerminal t) async {
    final ctrl = TextEditingController(text: t.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename terminal'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'e.g. Front desk A35'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    setState(() => t.name = name.trim().isEmpty ? null : name.trim());
    await _save();
  }

  Future<void> _remove(PaxTerminal t) async {
    setState(() => _terminals.remove(t));
    await _save();
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    _toast('Copied $value');
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final scanning = _progress != null;
    final sorted = [..._terminals]
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return _ipKey(a.ip).compareTo(_ipKey(b.ip));
      });

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Payment Terminals', style: text.headlineSmall),
              const SizedBox(width: 12),
              _CountPill(online: _terminals.where((t) => t.online).length, total: _terminals.length),
              const Spacer(),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _portCtrl,
                  enabled: !scanning,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: scanning || !_terminals.any((t) => t.online) ? null : _identifyAll,
                icon: const Icon(Icons.badge_outlined, size: 18),
                label: const Text('Identify all'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: scanning ? null : _scan,
                icon: const Icon(Icons.radar, size: 18),
                label: Text(scanning ? 'Scanning…' : 'Scan network'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Finds PAX terminals listening for POSLink on your subnet (default port 10009). '
            'Identify reads model and serial — it doesn\'t start a transaction.',
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
          const SizedBox(height: 12),
          if (scanning) ...[LinearProgressIndicator(value: _progress), const SizedBox(height: 12)],
          Expanded(
            child: sorted.isEmpty
                ? _Empty(scanning: scanning, onScan: _scan)
                : LayoutBuilder(
                    builder: (context, c) {
                      final cols = (c.maxWidth / 340).floor().clamp(1, 4);
                      return GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisExtent: 168,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: sorted.length,
                        itemBuilder: (_, i) {
                          final t = sorted[i];
                          return _TerminalCard(
                            terminal: t,
                            onIdentify: () => _identify(t),
                            onCopy: _copy,
                            onRename: () => _rename(t),
                            onRemove: () => _remove(t),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static int _ipKey(String ip) => ip.split('.').fold(0, (a, p) => a * 256 + (int.tryParse(p) ?? 0));
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.online, required this.total});

  final int online;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: .10), borderRadius: BorderRadius.circular(20)),
      child: Text(
        '$online online · $total saved',
        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}

class _TerminalCard extends StatelessWidget {
  const _TerminalCard({
    required this.terminal,
    required this.onIdentify,
    required this.onCopy,
    required this.onRename,
    required this.onRemove,
  });

  final PaxTerminal terminal;
  final VoidCallback onIdentify;
  final ValueChanged<String> onCopy;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = terminal;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dot = t.online ? const Color(0xFF10B981) : scheme.outline;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.point_of_sale, color: scheme.primary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.title, style: text.titleSmall, overflow: TextOverflow.ellipsis),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            t.online
                                ? 'Online${t.mode == null ? '' : ' · ${t.mode}'}'
                                : 'Offline · ${timeAgo(t.lastSeen)}',
                            style: text.labelSmall?.copyWith(color: scheme.outline),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (v) => switch (v) {
                    'rename' => onRename(),
                    'remove' => onRemove(),
                    _ => null,
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => onCopy(t.ip),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${t.ip}:${t.port}',
                      style: text.titleMedium?.copyWith(fontFamily: 'Consolas', fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.copy, size: 14, color: scheme.outline),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (t.serial != null) 'SN ${t.serial}',
                if (t.os != null) t.os!,
                if (t.name != null && t.model != null) t.model!,
              ].join(' · ').ifEmpty('Not identified yet'),
              style: text.bodySmall?.copyWith(color: scheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
            const Spacer(),
            Row(
              children: [
                if (t.serial != null)
                  TextButton.icon(
                    onPressed: () => onCopy(t.serial!),
                    icon: const Icon(Icons.tag, size: 16),
                    label: const Text('Copy SN'),
                  ),
                const Spacer(),
                t.identifying
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : TextButton.icon(
                        onPressed: onIdentify,
                        icon: const Icon(Icons.badge_outlined, size: 16),
                        label: const Text('Identify'),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.scanning, required this.onScan});

  final bool scanning;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.point_of_sale, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(scanning ? 'Scanning your network…' : 'No terminals yet', style: text.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Make sure the terminal and this PC are on the same network.',
            style: text.bodySmall?.copyWith(color: scheme.outline),
          ),
          if (!scanning) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.radar, size: 18),
              label: const Text('Scan network'),
            ),
          ],
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
