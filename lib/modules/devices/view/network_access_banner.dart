import 'package:flutter/material.dart';

import '../../../core/firewall.dart';

/// Warns when Windows Firewall / a Public network profile would block discovery, with a one-click fix.
class NetworkAccessBanner extends StatefulWidget {
  const NetworkAccessBanner({super.key});

  @override
  State<NetworkAccessBanner> createState() => _NetworkAccessBannerState();
}

class _NetworkAccessBannerState extends State<NetworkAccessBanner> {
  NetworkAccess? _access;
  var _makePrivate = true;
  var _fixing = false;
  var _dismissed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final a = await Firewall.check();
    if (mounted) setState(() => _access = a);
  }

  Future<void> _fix() async {
    setState(() => _fixing = true);
    final ok = await Firewall.fix(makePrivate: _makePrivate && (_access?.publicNetworks.isNotEmpty ?? false));
    await _check();
    if (!mounted) return;
    setState(() => _fixing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        width: 460,
        content: Text(ok ? 'Network access allowed — scan again' : 'Not applied (admin prompt cancelled?)'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = _access;
    if (a == null || a.ok || _dismissed) return const SizedBox.shrink();
    final problems = [
      if (a.missingRules.isNotEmpty) 'Windows Firewall blocks Slipway from receiving discovery replies',
      if (a.publicNetworks.isNotEmpty) '"${a.publicNetworks.join(', ')}" is a Public network (blocks local discovery)',
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withValues(alpha: .35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.shield_outlined, color: Colors.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Network scan may miss devices', style: TextStyle(fontWeight: FontWeight.w600)),
                  for (final p in problems) Text('• $p', style: const TextStyle(fontSize: 12.5)),
                ],
              ),
            ),
            if (a.publicNetworks.isNotEmpty)
              Row(
                children: [
                  Checkbox(value: _makePrivate, onChanged: (v) => setState(() => _makePrivate = v ?? true)),
                  const Text('Set network to Private', style: TextStyle(fontSize: 12.5)),
                  const SizedBox(width: 8),
                ],
              ),
            FilledButton.icon(
              onPressed: _fixing ? null : _fix,
              icon: _fixing
                  ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.admin_panel_settings_outlined, size: 18),
              label: const Text('Fix network access'),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: () => setState(() => _dismissed = true),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
