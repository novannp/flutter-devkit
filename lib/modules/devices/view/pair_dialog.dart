import '../../../core/qr.dart';
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../cubit/devices_cubit.dart';
import '../models/device.dart';
import '../services/adb_service.dart';

Future<void> showPairDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _PairDialog());

/// Wireless debugging pairing (Android 11+): QR like Android Studio, or a 6-digit code.
class _PairDialog extends StatefulWidget {
  const _PairDialog();

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  static final _rand = Random.secure();
  static String _token(int n) => List.generate(n, (_) => 'abcdefghjkmnpqrstuvwxyz23456789'[_rand.nextInt(31)]).join();

  // The phone advertises a pairing service with this name after scanning the QR.
  final _name = 'devkit-${_token(6)}';
  final _password = _token(10);
  final _ip = TextEditingController();
  final _port = TextEditingController();
  final _code = TextEditingController();
  final _connectIp = TextEditingController();
  final _connectPort = TextEditingController(text: '5555');
  var _switchTo5555 = true;
  Timer? _poll;
  List<AdbMdnsService> _pairing = const [];
  var _mode = 0;
  var _busy = false;
  String? _status;
  var _success = false;

  AdbService get adb => context.read<AdbService>();

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in [_ip, _port, _code, _connectIp, _connectPort]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _tick() async {
    if (_busy || _success) return;
    final services = (await adb.mdnsServices()).where((s) => s.isPairing).toList();
    if (!mounted) return;
    setState(() => _pairing = services);
    if (_mode != 0) return;
    final mine = services.where((s) => s.name == _name).firstOrNull;
    if (mine != null) await _pair(mine.target, _password);
  }

  Future<void> _pair(String target, String code) async {
    setState(() {
      _busy = true;
      _status = 'Pairing with $target…';
    });
    final r = await adb.pair(target, code);
    final out = '${r.stdout}${r.stderr}'.trim();
    final ok = out.contains('Successfully paired');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _success = ok;
      _status = ok ? 'Paired! Connecting device…' : 'Failed: $out';
    });
    if (!ok) return;
    await context.read<DevicesCubit>().refreshNow();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.outline, fontSize: 13);

    return AlertDialog(
      title: const Text('Pair device (Wireless debugging)'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Only needed once per phone. After that Flutter DevKit auto-connects whenever Wireless debugging is on. '
              'The phone and laptop must be on the same Wi-Fi.',
              style: muted,
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, icon: Icon(Icons.qr_code_2), label: Text('Scan QR')),
                ButtonSegment(value: 1, icon: Icon(Icons.pin), label: Text('Pairing code')),
                ButtonSegment(value: 2, icon: Icon(Icons.lan_outlined), label: Text('Connect by IP')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 16),
            if (_mode == 0) ...[
              Center(
                child: Container(
                  // Scanners want a light margin around the code.
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                  child: QrView(data: 'WIFI:T:ADB;S:$_name;P:$_password;;', size: 200),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'On the phone: Developer options → Wireless debugging → "Pair device with QR code", then scan this QR.',
                style: muted,
                textAlign: TextAlign.center,
              ),
            ] else if (_mode == 2) ...[
              Text(
                'For a phone that is already paired (use the IP & port under Wireless debugging), '
                'or a device with adb over TCP on port 5555.',
                style: muted,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _connectIp,
                      autofocus: true,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                      decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.36'),
                      onSubmitted: (_) => _connectManual(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _connectPort,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Port'),
                      onSubmitted: (_) => _connectManual(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _switchTo5555,
                onChanged: (v) => setState(() => _switchTo5555 = v ?? true),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Switch to port 5555 after connecting'),
                subtitle: const Text(
                  'Wireless debugging uses a random port; 5555 lets scans reconnect without pairing until reboot',
                ),
              ),
            ] else ...[
              Text(
                'On the phone: Developer options → Wireless debugging → "Pair device with pairing code". '
                'Enter the IP address, port and 6-digit code shown on the phone.',
                style: muted,
              ),
              const SizedBox(height: 12),
              if (_pairing.isNotEmpty)
                Wrap(
                  spacing: 6,
                  children: [
                    for (final s in _pairing)
                      ActionChip(
                        avatar: const Icon(Icons.wifi_tethering, size: 16),
                        label: Text(s.target),
                        tooltip: 'Auto-detected',
                        onPressed: () => setState(() {
                          _ip.text = s.ip;
                          _port.text = '${s.port}';
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _ip,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.:]'))],
                      decoration: const InputDecoration(labelText: 'IP address', hintText: '192.168.1.36'),
                      // Pasting "ip:port" from the phone fills both fields.
                      onChanged: (v) {
                        final m = RegExp(r'^([\d.]+):(\d+)$').firstMatch(v.trim());
                        if (m == null) return;
                        _ip.text = m[1]!;
                        _port.text = m[2]!;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _port,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Port', hintText: '37123'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _code,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Code', counterText: ''),
                      onSubmitted: (_) => _pairManual(),
                    ),
                  ),
                ],
              ),
            ],
            if (_status != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_busy) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_busy) const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(color: _success ? Colors.green : (_busy ? null : scheme.error)),
                    ),
                  ),
                ],
              ),
            ] else if (_mode == 0) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('Waiting for phone to scan QR…', style: muted),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (_mode == 1) FilledButton(onPressed: _busy ? null : _pairManual, child: const Text('Pair')),
        if (_mode == 2) FilledButton(onPressed: _busy ? null : _connectManual, child: const Text('Connect')),
      ],
    );
  }

  static final _ipRe = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  void _pairManual() {
    final ip = _ip.text.trim(), port = _port.text.trim(), code = _code.text.trim();
    if (!_ipRe.hasMatch(ip) || port.isEmpty || code.length != 6) {
      setState(() => _status = 'Enter the IP address, port and 6-digit code');
      return;
    }
    _pair('$ip:$port', code);
  }

  Future<void> _connectManual() async {
    final ip = _connectIp.text.trim(), port = _connectPort.text.trim();
    if (!_ipRe.hasMatch(ip) || port.isEmpty) {
      setState(() => _status = 'Enter a valid IP address and port');
      return;
    }
    final cubit = context.read<DevicesCubit>();
    setState(() {
      _busy = true;
      _success = false;
      _status = 'Connecting to $ip:$port…';
    });
    var msg = await cubit.connectTarget('$ip:$port');
    if (!mounted) return;
    final ok = msg.startsWith('Connected');
    if (ok && _switchTo5555 && port != '5555') {
      setState(() => _status = 'Connected — switching to port 5555…');
      final d = cubit.state.devices.where((d) => d.ip == ip && d.adb == AdbState.connected).firstOrNull;
      if (d != null) msg = await cubit.enablePort5555(d);
      if (!mounted) return;
    }
    setState(() {
      _busy = false;
      _success = ok;
      _status = msg;
    });
    if (!ok) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    Navigator.pop(context);
  }
}
