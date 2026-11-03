import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../extensions/work/work_service.dart' show openUrl;
import '../../core/panels.dart';
import 'packages_view.dart';

/// What a dialog asks of the command line: the exit code, and what it printed.
typedef ToolProbe = Future<(int, String)> Function(List<String> command);

ToolProbe probeIn(String root) => (command) async {
  try {
    final r = await Process.run(
      command.first,
      command.skip(1).toList(),
      workingDirectory: root,
      runInShell: Platform.isWindows,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(seconds: 45));
    return (r.exitCode, r.stdout as String);
  } on Exception catch (e) {
    return (-1, '$e');
  }
};

/// Opens a terminal window of its own, for what needs a real console. Only for fixed commands.
Future<void> openInSystemTerminal(List<String> command) async {
  if (Platform.isWindows) {
    // The first quoted word is start's window title, and /k leaves the window up to read the result.
    await Process.start('cmd', ['/c', 'start', 'HotRestart', 'cmd', '/k', ...command], mode: ProcessStartMode.detached);
  } else if (Platform.isMacOS) {
    await Process.run('osascript', ['-e', 'tell application "Terminal" to do script "${command.join(' ')}"', '-e', 'tell application "Terminal" to activate']);
  }
}

class FlutterToolCommand {
  const FlutterToolCommand(this.label, this.args, this.icon, {this.build = false});

  final String label;

  /// For `flutter`, unless it starts with `dart`.
  final String args;
  final IconData icon;
  final bool build;
}

/// Everything the palette can run. A build only shows when this computer and this project can do it.
List<FlutterToolCommand> flutterToolCommands(String root, {required bool usesFvm, String? device, String? host}) {
  final os = host ?? Platform.operatingSystem;
  bool has(String folder) => Directory(p.join(root, folder)).existsSync();
  FlutterToolCommand build(String label, String args, IconData icon) => FlutterToolCommand(label, 'build $args', icon, build: true);
  return [
    const FlutterToolCommand('Pub Get', 'pub get', Icons.download_outlined),
    const FlutterToolCommand('Pub Upgrade', 'pub upgrade', Icons.upgrade),
    const FlutterToolCommand('Pub Upgrade to Latest Majors', 'pub upgrade --major-versions', Icons.upgrade),
    const FlutterToolCommand('Pub Downgrade', 'pub downgrade', Icons.arrow_downward),
    const FlutterToolCommand('Pub Outdated', 'pub outdated', Icons.update),
    const FlutterToolCommand('Pub Deps', 'pub deps', Icons.account_tree_outlined),
    const FlutterToolCommand('Pub Cache Repair', 'pub cache repair', Icons.build_outlined),
    const FlutterToolCommand('Pub Publish (Dry Run)', 'pub publish --dry-run', Icons.publish),
    const FlutterToolCommand('Flutter Clean', 'clean', Icons.cleaning_services_outlined),
    const FlutterToolCommand('Flutter Analyze', 'analyze', Icons.rule),
    const FlutterToolCommand('Flutter Test', 'test', Icons.science_outlined),
    const FlutterToolCommand('Flutter Test with Coverage', 'test --coverage', Icons.science_outlined),
    const FlutterToolCommand('Flutter Doctor', 'doctor', Icons.medical_services_outlined),
    const FlutterToolCommand('Flutter Doctor (Verbose)', 'doctor -v', Icons.medical_services_outlined),
    const FlutterToolCommand('Flutter Devices', 'devices', Icons.devices),
    const FlutterToolCommand('Flutter Emulators', 'emulators', Icons.phone_android),
    const FlutterToolCommand('Flutter Channel', 'channel', Icons.alt_route),
    const FlutterToolCommand('Flutter Config', 'config --list', Icons.settings_outlined),
    const FlutterToolCommand('Flutter Precache', 'precache', Icons.cloud_download_outlined),
    // fvm pins the SDK, and picks a new one from its own panel.
    if (!usesFvm) const FlutterToolCommand('Flutter Upgrade SDK', 'upgrade', Icons.upgrade),
    if (File(p.join(root, 'l10n.yaml')).existsSync()) const FlutterToolCommand('Generate Localizations (gen-l10n)', 'gen-l10n', Icons.translate),
    if (device != null) ...[
      FlutterToolCommand('Flutter Install on Device', 'install -d $device', Icons.install_mobile),
      FlutterToolCommand('Flutter Logs from Device', 'logs -d $device', Icons.notes),
    ],
    if (has('android')) ...[
      build('Build APK', 'apk', Icons.android),
      build('Build APK (Debug)', 'apk --debug', Icons.android),
      build('Build App Bundle', 'appbundle', Icons.android),
    ],
    if (has('ios') && os == 'macos') ...[
      build('Build iOS', 'ios', Icons.phone_iphone),
      build('Build IPA', 'ipa', Icons.phone_iphone),
    ],
    if (has('macos') && os == 'macos') build('Build macOS', 'macos', Icons.desktop_mac_outlined),
    if (has('windows') && os == 'windows') build('Build Windows', 'windows', Icons.desktop_windows_outlined),
    if (has('linux') && os == 'linux') build('Build Linux', 'linux', Icons.computer),
    if (has('web')) build('Build Web', 'web', Icons.language),
    const FlutterToolCommand('Dart Fix (Preview)', 'dart fix --dry-run', Icons.auto_fix_high_outlined),
    const FlutterToolCommand('Dart Fix (Apply)', 'dart fix --apply', Icons.auto_fix_high_outlined),
    const FlutterToolCommand('Dart Format Project', 'dart format .', Icons.format_align_left),
  ];
}

Object? _jsonIn(String output) {
  final start = output.indexOf('{');
  if (start < 0) return null;
  try {
    return jsonDecode(output.substring(start));
  } on FormatException {
    return null;
  }
}

/// These reach a shell on Windows, so only what a version can look like gets through.
bool isValidFlutterVersion(String v) => RegExp(r'^[\w][\w.+-]*$').hasMatch(v);

class FvmVersion {
  const FvmVersion(this.name, {this.flutter, this.dart, this.isSetup = false});

  final String name;
  final String? flutter, dart;
  final bool isSetup;
}

class FvmRelease {
  const FvmRelease(this.version, {this.dart, this.date});

  final String version;
  final String? dart, date;
}

List<FvmVersion>? parseFvmVersions(String output) {
  final versions = (_jsonIn(output) as Map?)?['versions'];
  if (versions is! List) return null;
  return [
    for (final v in versions)
      if (v is Map && v['name'] is String && isValidFlutterVersion(v['name'] as String))
        FvmVersion(v['name'] as String, flutter: v['flutterSdkVersion'] as String?, dart: v['dartSdkVersion'] as String?, isSetup: v['isSetup'] == true),
  ];
}

List<FvmRelease>? parseFvmReleases(String output) {
  final versions = (_jsonIn(output) as Map?)?['versions'];
  if (versions is! List) return null;
  return [
    for (final v in versions)
      if (v is Map && v['version'] is String && isValidFlutterVersion(v['version'] as String))
        FvmRelease(v['version'] as String, dart: v['dart_sdk_version'] as String?, date: (v['release_date'] as String?)?.split('T').first),
  ];
}

String? pinnedFvmVersion(String root) {
  try {
    final config = jsonDecode(File(p.join(root, '.fvmrc')).readAsStringSync());
    return config is Map ? config['flutter'] as String? : null;
  } on Exception {
    return null;
  }
}

Widget _action(String label, VoidCallback? onPressed) => Padding(
  padding: const EdgeInsets.only(left: 4),
  child: TextButton(
    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, textStyle: const TextStyle(fontSize: 12.5)),
    onPressed: onPressed,
    child: Text(label),
  ),
);

/// Which Flutter a project uses, through fvm's own JSON API.
class FvmDialog extends StatefulWidget {
  const FvmDialog({super.key, required this.root, required this.onRun, this.probe});

  final String root;

  /// Runs in the Output panel, after this dialog has closed.
  final void Function(List<String> command) onRun;
  final ToolProbe? probe;

  @override
  State<FvmDialog> createState() => _FvmDialogState();
}

class _FvmDialogState extends State<FvmDialog> {
  late final _probe = widget.probe ?? probeIn(widget.root);
  var _available = false;
  var _loading = true;
  var _missing = false;
  var _installed = const <FvmVersion>[];
  var _releases = const <FvmRelease>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final (code, listed) = await _probe(['fvm', 'api', 'list', '--compress']);
    final versions = code == 0 ? parseFvmVersions(listed) : null;
    if (!mounted) return;
    if (versions == null) {
      setState(() {
        _missing = true;
        _loading = false;
      });
      return;
    }
    setState(() {
      _installed = versions;
      _loading = false;
    });
    final (_, released) = await _probe(['fvm', 'api', 'releases', '--limit', '40', '--filter-channel', 'stable', '--compress']);
    if (mounted) setState(() => _releases = parseFvmReleases(released) ?? const []);
  }

  void _run(List<String> command) {
    Navigator.pop(context);
    widget.onRun(command);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pinned = pinnedFvmVersion(widget.root);
    final small = TextStyle(fontSize: 12, color: scheme.outline);
    Widget row(String title, String? detail, List<Widget> actions, {bool current = false}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 10, 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    if (current) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle, size: 14, color: scheme.primary),
                      Text(' This project', style: TextStyle(fontSize: 12, color: scheme.primary)),
                    ],
                  ],
                ),
                if (detail != null) Text(detail, style: small),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );

    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_missing) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("FVM isn't installed, or isn't on your PATH.", textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: () => _run(const ['dart', 'pub', 'global', 'activate', 'fvm']), child: const Text('Install FVM')),
              const SizedBox(height: 6),
              TextButton(onPressed: () => openUrl('https://fvm.app/documentation/getting-started/installation'), child: const Text('Other ways to install it')),
            ],
          ),
        ),
      );
    } else if (_available) {
      final have = {for (final v in _installed) v.name};
      body = _releases.isEmpty
          ? Center(child: Text('Looking up releases…', style: small))
          : ListView(
              children: [
                for (final r in _releases)
                  row(r.version, ['Dart ${r.dart ?? '?'}', ?r.date].join('  •  '), [
                    if (!have.contains(r.version)) _action('Install', () => _run(['fvm', 'install', r.version])),
                    _action('Use here', r.version == pinned ? null : () => _run(['fvm', 'use', r.version, '--force'])),
                  ], current: r.version == pinned),
              ],
            );
    } else {
      body = _installed.isEmpty
          ? Center(child: Text('No Flutter versions installed yet.', style: small))
          : ListView(
              children: [
                for (final v in _installed)
                  row(v.name, v.isSetup ? 'Flutter ${v.flutter ?? '?'}  •  Dart ${v.dart ?? '?'}' : 'Not set up yet', [
                    _action('Use here', v.name == pinned ? null : () => _run(['fvm', 'use', v.name, '--force'])),
                    _action('Set global', () => _run(['fvm', 'global', v.name, '--force'])),
                    _action('Remove', v.name == pinned ? null : () => _run(['fvm', 'remove', v.name])),
                  ], current: v.name == pinned),
              ],
            );
    }

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 620,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
              child: Row(
                children: [
                  const Expanded(child: Text('Flutter versions (FVM)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                  if (!_missing) _action('Doctor', () => _run(const ['fvm', 'doctor'])),
                  IconButton(tooltip: 'Close', iconSize: 18, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(pinned == null ? "This project doesn't pin a version yet. Use here pins one in .fvmrc." : 'This project is pinned to $pinned in .fvmrc.', style: small),
            ),
            if (!_missing && !_loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                child: SizedBox(
                  height: 34,
                  child: Row(
                    children: [
                      PillTab(selected: !_available, onTap: () => setState(() => _available = false), child: const Text('Installed', style: TextStyle(fontSize: 13))),
                      PillTab(selected: _available, onTap: () => setState(() => _available = true), child: const Text('Available', style: TextStyle(fontSize: 13))),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// Firebase project ids are short, lowercase and can't end in a dash.
bool isValidFirebaseId(String id) => RegExp(r'^[a-z][a-z0-9-]{4,28}[a-z0-9]$').hasMatch(id);

bool isValidFirebaseName(String name) => RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _-]{3,29}$').hasMatch(name);

String? parseFirebaseAccount(String output) {
  final result = (_jsonIn(output) as Map?)?['result'];
  if (result is! List || result.isEmpty) return null;
  final first = result.first;
  final user = first is Map ? first['user'] : null;
  return user is Map ? user['email'] as String? : null;
}

class FirebaseProject {
  const FirebaseProject(this.id, this.name);

  final String id, name;
}

List<FirebaseProject>? parseFirebaseProjects(String output) {
  final result = (_jsonIn(output) as Map?)?['result'];
  if (result is! List) return null;
  return [
    for (final e in result)
      if (e is Map && e['projectId'] is String && isValidFirebaseId(e['projectId'] as String))
        FirebaseProject(e['projectId'] as String, e['displayName'] as String? ?? e['projectId'] as String),
  ];
}

/// The platforms a Flutter project has folders for, as FlutterFire names them.
List<String> flutterPlatformsIn(String root) => [
  for (final name in const ['android', 'ios', 'macos', 'web', 'windows', 'linux'])
    if (Directory(p.join(root, name)).existsSync()) name,
];

const firebasePackages = {
  'firebase_core': 'Required by all of these',
  'firebase_auth': 'Sign-in',
  'cloud_firestore': 'Firestore database',
  'firebase_storage': 'File storage',
  'firebase_messaging': 'Push notifications',
  'firebase_analytics': 'Analytics',
  'firebase_crashlytics': 'Crash reports',
  'firebase_remote_config': 'Remote Config',
  'cloud_functions': 'Cloud Functions',
};

const _initCode = '''import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}''';

const _flutterfire = ['dart', 'pub', 'global', 'run', 'flutterfire_cli:flutterfire'];

/// Connects a project to Firebase in the order it has to happen, showing what's done already.
class FirebaseDialog extends StatefulWidget {
  const FirebaseDialog({super.key, required this.root, required this.onRun, this.onSignIn = openInSystemTerminal, this.probe});

  final String root;
  final void Function(List<String> command) onRun;

  /// Signing in insists on a real console: the Firebase CLI refuses to run inside the app's terminal.
  final Future<void> Function(List<String> command) onSignIn;
  final ToolProbe? probe;

  @override
  State<FirebaseDialog> createState() => _FirebaseDialogState();
}

class _FirebaseDialogState extends State<FirebaseDialog> {
  late final _probe = widget.probe ?? probeIn(widget.root);
  final _newId = TextEditingController();
  final _newName = TextEditingController();
  var _loading = true;
  var _hasFirebase = false, _hasFlutterFire = false, _hasNpm = false;
  String? _account;
  var _projects = const <FirebaseProject>[];
  String? _project;
  late final _platforms = flutterPlatformsIn(widget.root).toSet();
  late final _allPlatforms = flutterPlatformsIn(widget.root);
  var _declared = const <String>{};
  final _wanted = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _newId.dispose();
    _newName.dispose();
    super.dispose();
  }

  bool get _configured => File(p.join(widget.root, 'lib', 'firebase_options.dart')).existsSync();

  /// The project chosen when `flutterfire configure` last ran.
  String? _configuredProject() {
    try {
      final data = jsonDecode(File(p.join(widget.root, '.firebaserc')).readAsStringSync());
      final projects = data is Map ? data['projects'] : null;
      return projects is Map ? projects['default'] as String? : null;
    } on Exception {
      return null;
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _probe(const ['firebase', '--version']),
      _probe(const ['dart', 'pub', 'global', 'list']),
      _probe(const ['npm', '--version']),
    ]);
    var declared = const <String>{};
    try {
      declared = parseDeclaredPackages(File(p.join(widget.root, 'pubspec.yaml')).readAsStringSync(), null).map((x) => x.name).toSet();
    } on FileSystemException {
      // Without a pubspec the packages step just has nothing checked.
    }
    final hasFirebase = results[0].$1 == 0;
    String? account;
    var projects = const <FirebaseProject>[];
    if (hasFirebase) {
      account = parseFirebaseAccount((await _probe(const ['firebase', 'login:list', '--json'])).$2);
      if (account != null) projects = parseFirebaseProjects((await _probe(const ['firebase', 'projects:list', '--json'])).$2) ?? const [];
    }
    if (!mounted) return;
    setState(() {
      _hasFirebase = hasFirebase;
      _hasFlutterFire = results[1].$2.contains('flutterfire_cli');
      _hasNpm = results[2].$1 == 0;
      _account = account;
      _projects = projects;
      final existing = _configuredProject();
      _project = projects.any((x) => x.id == existing) ? existing : projects.firstOrNull?.id;
      _declared = declared;
      _wanted
        ..clear()
        ..addAll(declared.where(firebasePackages.containsKey));
      if (!declared.contains('firebase_core')) _wanted.add('firebase_core');
      _loading = false;
    });
  }

  void _run(List<String> command) {
    Navigator.pop(context);
    widget.onRun(command);
  }

  Widget _step(int number, String title, bool done, Widget body, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 10),
          child: done
              ? Icon(Icons.check_circle, size: 20, color: scheme.primary)
              : CircleAvatar(radius: 10, backgroundColor: scheme.surfaceContainerHigh, child: Text('$number', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              body,
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant);
    final project = _project;
    final newId = _newId.text.trim(), newName = _newName.text.trim();
    final canCreate = isValidFirebaseId(newId) && (newName.isEmpty || isValidFirebaseName(newName));
    final toAdd = _wanted.difference(_declared);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 640,
        height: 620,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('Firebase', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                  IconButton(tooltip: 'Check again', iconSize: 18, onPressed: _loading ? null : () {
                    setState(() => _loading = true);
                    unawaited(_load());
                  }, icon: const Icon(Icons.refresh)),
                  IconButton(tooltip: 'Close', iconSize: 18, onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        _step(1, 'Install the tools', _hasFirebase && _hasFlutterFire, Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (_hasFirebase && _hasFlutterFire) Text('Firebase CLI and FlutterFire CLI are ready.', style: small),
                            if (!_hasFirebase && _hasNpm) OutlinedButton(onPressed: () => _run(const ['npm', 'install', '-g', 'firebase-tools']), child: const Text('Install Firebase CLI')),
                            if (!_hasFirebase && !_hasNpm) OutlinedButton(onPressed: () => openUrl('https://firebase.google.com/docs/cli#install_the_firebase_cli'), child: const Text('Get Firebase CLI')),
                            if (!_hasFlutterFire) OutlinedButton(onPressed: () => _run(const ['dart', 'pub', 'global', 'activate', 'flutterfire_cli']), child: const Text('Install FlutterFire CLI')),
                          ],
                        ), scheme),
                        _step(2, 'Sign in', _account != null, Row(
                          children: [
                            Expanded(child: Text(_account == null ? 'A terminal window opens to sign in with Google. When it says you are in, press Check again here.' : 'Signed in as $_account.', style: small)),
                            OutlinedButton(
                              onPressed: !_hasFirebase ? null : () => unawaited(widget.onSignIn(['firebase', if (_account == null) 'login' else 'login:add'])),
                              child: Text(_account == null ? 'Sign in' : 'Add account'),
                            ),
                          ],
                        ), scheme),
                        _step(3, 'Choose a Firebase project', project != null, Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_projects.isNotEmpty)
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButton<String>(
                                      value: project,
                                      isExpanded: true,
                                      isDense: true,
                                      items: [for (final x in _projects) DropdownMenuItem(value: x.id, child: Text('${x.name}  (${x.id})', style: const TextStyle(fontSize: 13)))],
                                      onChanged: (v) => setState(() => _project = v),
                                    ),
                                  ),
                                  if (project != null) TextButton(onPressed: () => openUrl('https://console.firebase.google.com/project/$project/overview'), child: const Text('Open console')),
                                ],
                              ),
                            const SizedBox(height: 6),
                            Text('Or create a new one:', style: small),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(child: TextField(controller: _newId, onChanged: (_) => setState(() {}), style: const TextStyle(fontSize: 13), decoration: const InputDecoration(isDense: true, hintText: 'project-id'))),
                                const SizedBox(width: 6),
                                Expanded(child: TextField(controller: _newName, onChanged: (_) => setState(() {}), style: const TextStyle(fontSize: 13), decoration: const InputDecoration(isDense: true, hintText: 'Display name (optional)'))),
                                const SizedBox(width: 6),
                                OutlinedButton(
                                  onPressed: _account != null && canCreate
                                      ? () => _run(['firebase', 'projects:create', newId, if (newName.isNotEmpty) ...['--display-name', newName]])
                                      : null,
                                  child: const Text('Create'),
                                ),
                              ],
                            ),
                            if (newId.isNotEmpty && !isValidFirebaseId(newId))
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('6 to 30 lowercase letters, digits and dashes, starting with a letter.', style: TextStyle(fontSize: 12, color: scheme.error)),
                              ),
                          ],
                        ), scheme),
                        _step(4, 'Connect this app', _configured, Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_configured ? 'lib/firebase_options.dart exists. Run this again after adding a platform.' : 'Registers your app with the project and writes lib/firebase_options.dart.', style: small),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              children: [
                                for (final name in _allPlatforms)
                                  FilterChip(
                                    label: Text(name, style: const TextStyle(fontSize: 12)),
                                    visualDensity: VisualDensity.compact,
                                    selected: _platforms.contains(name),
                                    onSelected: (on) => setState(() => on ? _platforms.add(name) : _platforms.remove(name)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            FilledButton(
                              onPressed: project != null && _hasFlutterFire && _platforms.isNotEmpty
                                  ? () => _run([..._flutterfire, 'configure', '--project=$project', '--yes', '--platforms=${_platforms.join(',')}'])
                                  : null,
                              child: const Text('Run flutterfire configure'),
                            ),
                          ],
                        ), scheme),
                        _step(5, 'Add Firebase packages', _declared.contains('firebase_core'), Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 6,
                              runSpacing: 2,
                              children: [
                                for (final e in firebasePackages.entries)
                                  Tooltip(
                                    message: e.value,
                                    child: FilterChip(
                                      label: Text(e.key, style: const TextStyle(fontSize: 12)),
                                      visualDensity: VisualDensity.compact,
                                      selected: _wanted.contains(e.key),
                                      // Already in the project: pub remove is the Packages panel's job.
                                      onSelected: _declared.contains(e.key) ? null : (on) => setState(() => on ? _wanted.add(e.key) : _wanted.remove(e.key)),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            OutlinedButton(
                              onPressed: toAdd.isEmpty ? null : () => _run(['flutter', 'pub', 'add', ...toAdd]),
                              child: Text(toAdd.isEmpty ? 'All added' : 'Add ${toAdd.length} ${toAdd.length == 1 ? 'package' : 'packages'}'),
                            ),
                          ],
                        ), scheme),
                        _step(6, 'Start Firebase in your app', false, Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Put this in lib/main.dart:', style: small),
                            const SizedBox(height: 4),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(6)),
                              child: SelectableText(_initCode, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12)),
                            ),
                            TextButton.icon(
                              onPressed: () => Clipboard.setData(const ClipboardData(text: _initCode)),
                              icon: const Icon(Icons.copy, size: 14),
                              label: const Text('Copy'),
                            ),
                          ],
                        ), scheme),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
