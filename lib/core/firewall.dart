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

class Firewall {
  static const ruleName = 'Ravo DevKit';

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

  /// Adds inbound allow rules (and optionally makes Public networks Private) behind one UAC prompt.
  static Future<bool> fix({required bool makePrivate}) async {
    final lines = [
      'netsh advfirewall firewall delete rule name="$ruleName" | Out-Null',
      for (final p in programs)
        'netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow program="$p" enable=yes profile=any | Out-Null',
      if (makePrivate) "Get-NetConnectionProfile | Where-Object NetworkCategory -eq 'Public' | Set-NetConnectionProfile -NetworkCategory Private",
    ];
    final script = File('${Directory.systemTemp.path}${Platform.pathSeparator}ravo_devkit_network_fix.ps1');
    await script.writeAsString(lines.join('\r\n'));
    final r = await Tools.run('powershell', [
      '-NoProfile',
      '-Command',
      "try { Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden "
          "-ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${script.path}'; exit 0 } catch { exit 1 }",
    ], timeout: const Duration(minutes: 2));
    final ok = r.ok && (await check()).missingRules.isEmpty;
    History.activity('network', 'Fix network access: ${ok ? 'applied' : 'not applied'}', {'makePrivate': makePrivate});
    return ok;
  }
}
