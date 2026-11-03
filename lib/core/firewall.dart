import 'dart:io';

import 'tools.dart';
import 'history.dart';

class NetworkAccess {
  const NetworkAccess({required this.missingRules, required this.publicNetworks});

  /// Executables that have no inbound firewall rule (mDNS replies, printer server need inbound).
  final List<String> missingRules;

  /// Connected networks on the Public profile, where Windows blocks inbound by default.
  final List<String> publicNetworks;

  bool get ok => missingRules.isEmpty && publicNetworks.isEmpty;
}

/// A batch file, which runs without touching PowerShell's execution policy. Public networks stay protected.
String firewallFixScript(String rule, List<String> programs) => [
  '@echo off',
  'chcp 65001 >nul',
  'netsh advfirewall firewall delete rule name="$rule" >nul',
  for (final p in programs) 'netsh advfirewall firewall add rule name="$rule" dir=in action=allow program="$p" enable=yes profile=private,domain >nul',
].join('\r\n');

class Firewall {
  static const ruleName = 'Slipway';

  static List<String> get programs {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    return [
      Platform.resolvedExecutable,
      for (final exe in ['adb.exe', 'scrcpy.exe'])
        if (File('$dir${sep}scrcpy$sep$exe').existsSync()) '$dir${sep}scrcpy$sep$exe',
    ];
  }

  static Future<String> _ps(String script) async => (await Tools.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ], timeout: const Duration(seconds: 20))).stdout.trim();

  static Future<NetworkAccess> check() async {
    if (!Platform.isWindows) return const NetworkAccess(missingRules: [], publicNetworks: []);
    // Per-program lookup: listing every rule takes ~20s.
    final checks = programs
        .map(
          (p) =>
              "if (-not (Get-NetFirewallApplicationFilter -Program '${p.replaceAll("'", "''")}' -ErrorAction SilentlyContinue | "
              "Get-NetFirewallRule | Where-Object { \$_.Direction -eq 'Inbound' -and \$_.Action -eq 'Allow' -and \$_.Enabled -eq 'True' })) "
              "{ '${p.replaceAll("'", "''")}' }",
        )
        .join('; ');
    final missing = (await _ps(checks)).split(RegExp(r'\r?\n')).where((s) => s.trim().isNotEmpty).toList();
    final public = (await _ps(
      r"Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | ForEach-Object { $_.Name }",
    )).split(RegExp(r'\r?\n')).where((s) => s.trim().isNotEmpty).toList();
    return NetworkAccess(missingRules: missing, publicNetworks: public);
  }

  /// Adds inbound allow rules behind one UAC prompt, for what the banner asked to confirm.
  static Future<bool> fix() async {
    final script = File('${Directory.systemTemp.path}${Platform.pathSeparator}slipway_network_fix.cmd');
    await script.writeAsString(firewallFixScript(ruleName, programs));
    final r = await Tools.run('powershell', [
      '-NoProfile',
      '-Command',
      "try { Start-Process -FilePath '${script.path.replaceAll("'", "''")}' -Verb RunAs -Wait; exit 0 } catch { exit 1 }",
    ], timeout: const Duration(minutes: 2));
    final ok = r.ok && (await check()).missingRules.isEmpty;
    History.activity('network', 'Fix network access: ${ok ? 'applied' : 'not applied'}', const {});
    return ok;
  }
}
