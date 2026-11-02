import 'package:shared_preferences/shared_preferences.dart';

import 'local_builds.dart';

class KnownApp {
  const KnownApp(this.name, this.short, this.package);

  final String name;
  final String short;
  final String package;
}

const appPrefixesKey = 'app_package_prefixes';

// These end up in device shell commands, and a gradle file can hold anything.
bool isValidPackageId(String id) => RegExp(r'^[A-Za-z][\w.]*$').hasMatch(id);

/// "My apps": every Flutter project in the project folders.
var knownApps = const <KnownApp>[];

/// Extra package prefixes from Settings, for apps installed on devices but not cloned here.
var appPrefixes = const <String>[];

Future<void> loadApps() async {
  final prefs = await SharedPreferences.getInstance();
  appPrefixes = (prefs.getStringList(appPrefixesKey) ?? const <String>[]).where(isValidPackageId).toList();
  final byPackage = <String, KnownApp>{
    for (final p in await scanFlutterProjects())
      if (isValidPackageId(p.package)) p.package: KnownApp(p.name, p.name, p.package),
  };
  knownApps = byPackage.values.toList();
}

Future<void> saveAppPrefixes(List<String> prefixes) async {
  appPrefixes = prefixes.where(isValidPackageId).toList();
  await (await SharedPreferences.getInstance()).setStringList(appPrefixesKey, appPrefixes);
}

bool isOurApp(String package) => appByPackage(package) != null || appPrefixes.any(package.startsWith);

KnownApp? appByPackage(String package) => knownApps.where((a) => a.package == package).firstOrNull;

String appName(String package) => appByPackage(package)?.name ?? package;

String appShort(String package) => appByPackage(package)?.short ?? package.split('.').last;

/// Device shell snippet printing the installed packages that are "my apps", one per line.
String ourPackagesShell() {
  String esc(String s) => s.replaceAll('.', r'\.');
  final patterns = [for (final a in knownApps) '${esc(a.package)}\$', ...appPrefixes.map(esc)];
  if (patterns.isEmpty) return 'true';
  return "pm list packages --user 0 | cut -d: -f2 | grep -E '^(${patterns.join('|')})'";
}
