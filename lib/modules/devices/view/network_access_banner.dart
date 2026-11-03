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
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Change Windows Firewall?'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Windows will ask for admin rights. Then a rule named "${Firewall.ruleName}" lets these programs receive connections on private and domain networks:'),
              const SizedBox(height: 8),
              for (final p in Firewall.programs) Text(p, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              const Text('To undo it, delete that rule in Windows Defender Firewall. Nothing else changes.'),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change firewall')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _fixing = true);
    final ok = await Firewall.fix();
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
      if (a.missingRules.isNotEmpty) 'Windows Firewall blocks HotRestart from receiving discovery replies',
      if (a.publicNetworks.isNotEmpty) '"${a.publicNetworks.join(', ')}" is a Public network, which blocks discovery. If you trust it, make it Private in Windows Settings',
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
            if (a.missingRules.isNotEmpty) FilledButton.icon(
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
