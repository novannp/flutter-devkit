import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../extensions/work/work_service.dart' show openUrl;
import 'dart_sdk.dart';

enum PubKind { direct, dev, transitive }

class PubPackage {
  const PubPackage(this.name, this.kind, {this.current, this.upgradable, this.latest, this.discontinued = false, this.fromPubDev = true});

  final String name;
  final PubKind kind;
  final String? current, upgradable, latest;
  final bool discontinued;

  /// False for the SDK, git and path dependencies, which pub.dev knows nothing about.
  final bool fromPubDev;

  bool get canUpgrade => upgradable != null && upgradable != current;
  bool get hasNewer => latest != null && latest != current;
}

class PubSearchResult {
  const PubSearchResult(this.name, {this.version, this.description});

  final String name;
  final String? version, description;
}

/// Runs in a shell on Windows, so nothing but a real package name may reach the command line.
bool isValidPubName(String name) => RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name);

List<PubPackage>? parsePubOutdated(String output) {
  final start = output.indexOf('{');
  if (start < 0) return null;
  final Object? data;
  try {
    data = jsonDecode(output.substring(start));
  } on FormatException {
    return null;
  }
  final list = data is Map ? data['packages'] : null;
  if (list is! List) return null;
  String? version(Object? v) => v is Map && v['version'] is String ? v['version'] as String : null;
  return [
    for (final e in list)
      if (e is Map && e['package'] is String)
        PubPackage(
          e['package'] as String,
          switch (e['kind']) {
            'direct' => PubKind.direct,
            'dev' => PubKind.dev,
            _ => PubKind.transitive,
          },
          current: version(e['current']),
          upgradable: version(e['upgradable']),
          latest: version(e['latest']),
          discontinued: e['isDiscontinued'] == true,
        ),
  ];
}

/// What pubspec.yaml and pubspec.lock say, which needs neither the network nor a solve.
List<PubPackage> parseDeclaredPackages(String pubspec, String? lock) {
  final versions = <String, String>{};
  String? locked;
  for (final line in const LineSplitter().convert(lock ?? '')) {
    final name = RegExp(r'^  ([\w-]+):\s*$').firstMatch(line);
    if (name != null) {
      locked = name[1];
    } else if (locked != null) {
      final v = RegExp(r'''^    version: ["']?([^"']+)["']?\s*$''').firstMatch(line);
      if (v != null) versions[locked] = v[1]!;
    }
  }

  final found = <String, (PubKind, bool)>{};
  PubKind? section;
  String? last;
  for (final raw in const LineSplitter().convert(pubspec)) {
    final line = raw.split(' #').first.trimRight();
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (!line.startsWith(' ')) {
      section = switch (line.split(':').first) {
        'dependencies' => PubKind.direct,
        'dev_dependencies' => PubKind.dev,
        _ => null,
      };
      last = null;
      continue;
    }
    if (section == null) continue;
    final entry = RegExp(r'^  (\w+):\s*(.*)$').firstMatch(line);
    if (entry != null) {
      last = entry[1];
      found[last!] = (section, !RegExp(r'\b(sdk|git|path):').hasMatch(entry[2]!));
    } else if (last != null && RegExp(r'^\s+(sdk|git|path):').hasMatch(line)) {
      found[last] = (section, false);
    }
  }
  return [
    for (final e in found.entries) PubPackage(e.key, e.value.$1, current: versions[e.key], fromPubDev: e.value.$2),
  ];
}

/// Sorts the dependency sections by name, with the SDK's own packages first, as Flutter's templates have them.
/// An entry keeps its nested lines and the comments above it; everything else stays exactly as written.
String sortPubspecDependencies(String pubspec) {
  final lineBreak = pubspec.contains('\r\n') ? '\r\n' : '\n';
  final lines = pubspec.split(RegExp(r'\r?\n'));
  final out = <String>[];
  const sections = {'dependencies:', 'dev_dependencies:', 'dependency_overrides:'};
  var i = 0;
  while (i < lines.length) {
    final line = lines[i++];
    out.add(line);
    if (!sections.contains(line.trimRight())) continue;

    final entries = <(String, bool, List<String>)>[];
    var comments = <String>[];
    final tail = <String>[];
    while (i < lines.length) {
      final next = lines[i];
      if (next.trim().isEmpty || next.startsWith('  #')) {
        // Only a comment followed by another entry belongs to that entry.
        var ahead = i;
        while (ahead < lines.length && (lines[ahead].trim().isEmpty || lines[ahead].startsWith('  #'))) {
          ahead++;
        }
        final more = ahead < lines.length && RegExp(r'^  \w+:').hasMatch(lines[ahead]);
        if (!more) break;
        comments.add(next);
        i++;
        continue;
      }
      final entry = RegExp(r'^  (\w+):(.*)$').firstMatch(next);
      if (entry == null) break;
      final body = [...comments, next];
      comments = [];
      i++;
      var sdk = RegExp(r'\bsdk:').hasMatch(entry[2]!);
      while (i < lines.length && lines[i].startsWith('   ')) {
        if (RegExp(r'^\s+sdk:').hasMatch(lines[i])) sdk = true;
        body.add(lines[i++]);
      }
      entries.add((entry[1]!, sdk, body));
    }
    tail.addAll(comments);
    entries.sort((a, b) {
      if (a.$2 != b.$2) return a.$2 ? -1 : 1;
      return a.$1.compareTo(b.$1);
    });
    for (final e in entries) {
      out.addAll(e.$3);
    }
    out.addAll(tail);
  }
  return out.join(lineBreak);
}

/// Adds what `pub outdated` knows to the declared list, and the packages that came in through others.
List<PubPackage> mergePackages(List<PubPackage> declared, List<PubPackage> outdated) {
  final known = {for (final o in outdated) o.name: o};
  final names = {for (final d in declared) d.name};
  return [
    for (final d in declared)
      if (known[d.name] case final o?)
        PubPackage(d.name, d.kind, current: o.current ?? d.current, upgradable: o.upgradable, latest: d.fromPubDev ? o.latest : null, discontinued: o.discontinued, fromPubDev: d.fromPubDev)
      else
        d,
    for (final o in outdated)
      if (!names.contains(o.name)) o,
  ];
}

Future<List<PubPackage>?> checkOutdated(String root) async {
  final fvm = projectUsesFvm(root);
  try {
    final r = await Process.run(
      fvm ? 'fvm' : 'flutter',
      [if (fvm) 'flutter', 'pub', 'outdated', '--json', '--show-all'],
      workingDirectory: root,
      runInShell: Platform.isWindows,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(const Duration(minutes: 2));
    return r.exitCode == 0 ? parsePubOutdated(r.stdout as String) : null;
  } on Exception {
    return null;
  }
}

Future<Object?> _getJson(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close().timeout(const Duration(seconds: 10));
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  return jsonDecode(await response.transform(utf8.decoder).join());
}

Future<List<PubSearchResult>> searchPubDev(String query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final found = await _getJson(client, Uri.https('pub.dev', '/api/search', {'q': query}));
    final names = [
      if (found is Map && found['packages'] is List)
        for (final e in found['packages'] as List)
          if (e is Map && e['package'] is String) e['package'] as String,
    ].take(8);
    return await Future.wait([
      for (final name in names)
        () async {
          try {
            final info = await _getJson(client, Uri.https('pub.dev', '/api/packages/$name'));
            final latest = info is Map ? info['latest'] : null;
            final pubspec = latest is Map ? latest['pubspec'] : null;
            return PubSearchResult(
              name,
              version: latest is Map ? latest['version'] as String? : null,
              description: pubspec is Map ? pubspec['description'] as String? : null,
            );
          } on Exception {
            return PubSearchResult(name);
          }
        }(),
    ]);
  } finally {
    client.close();
  }
}

class PackagesView extends StatefulWidget {
  const PackagesView({
    super.key,
    required this.root,
    required this.visible,
    required this.busy,
    required this.revision,
    required this.onRun,
    required this.onSort,
    this.check = checkOutdated,
    this.search = searchPubDev,
  });

  final String root;

  /// Checking for updates runs pub over the network, so it waits until someone looks.
  final bool visible;
  final bool busy;

  /// Goes up when a pub command finishes.
  final int revision;
  final void Function(String args) onRun;
  final VoidCallback onSort;
  final Future<List<PubPackage>?> Function(String root) check;
  final Future<List<PubSearchResult>> Function(String query) search;

  @override
  State<PackagesView> createState() => _PackagesViewState();
}

class _PackagesViewState extends State<PackagesView> {
  final _query = TextEditingController();
  var _packages = const <PubPackage>[];
  var _hasPubspec = true;
  var _checking = false;
  var _checkFailed = false;
  var _stale = true;
  var _showTransitive = false;
  var _token = 0;

  Timer? _debounce;
  var _searchToken = 0;
  var _searching = false;
  String? _searchError;
  var _results = const <PubSearchResult>[];

  @override
  void initState() {
    super.initState();
    if (widget.visible) unawaited(_reload());
  }

  @override
  void didUpdateWidget(PackagesView old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision || old.root != widget.root) _stale = true;
    if (widget.visible && _stale) unawaited(_reload());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    _stale = false;
    final token = ++_token;
    final pubspec = File(p.join(widget.root, 'pubspec.yaml'));
    final lock = File(p.join(widget.root, 'pubspec.lock'));
    List<PubPackage> declared = const [];
    var exists = false;
    try {
      exists = await pubspec.exists();
      if (exists) declared = parseDeclaredPackages(await pubspec.readAsString(), await lock.exists() ? await lock.readAsString() : null);
    } on FileSystemException {
      // Being rewritten by pub right now: the list comes from the check below.
    }
    if (!mounted || token != _token) return;
    setState(() {
      _hasPubspec = exists;
      _packages = declared;
      _checking = exists;
      _checkFailed = false;
    });
    if (!exists) return;
    final outdated = await widget.check(widget.root);
    if (!mounted || token != _token) return;
    setState(() {
      _checking = false;
      _checkFailed = outdated == null;
      if (outdated != null) _packages = mergePackages(declared, outdated);
    });
  }

  void _onQuery(String text) {
    _debounce?.cancel();
    final token = ++_searchToken;
    final query = text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final results = await widget.search(query);
        if (!mounted || token != _searchToken) return;
        setState(() {
          _results = results;
          _searching = false;
          _searchError = null;
        });
      } on Exception {
        if (!mounted || token != _searchToken) return;
        setState(() {
          _results = const [];
          _searching = false;
          _searchError = "Couldn't reach pub.dev.";
        });
      }
    });
  }

  void _add(String name, {bool dev = false}) {
    if (!isValidPubName(name)) return;
    _query.clear();
    _onQuery('');
    widget.onRun('pub add $name${dev ? ' --dev' : ''}');
  }

  Future<void> _remove(PubPackage package) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${package.name}?'),
        content: const Text('It comes out of pubspec.yaml, and code that imports it stops compiling.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (sure == true && isValidPubName(package.name)) widget.onRun('pub remove ${package.name}');
  }

  Widget _heading(String text, ColorScheme scheme, {VoidCallback? onTap, bool? open}) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant))),
          if (open != null) Icon(open ? Icons.expand_more : Icons.chevron_right, size: 15, color: scheme.outline),
        ],
      ),
    ),
  );

  Widget _row(PubPackage package, ColorScheme scheme) {
    final valid = isValidPubName(package.name);
    final action = !widget.busy && valid;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 2),
      child: SizedBox(
        height: 42,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(package.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  Text.rich(
                    TextSpan(
                      text: package.current ?? (package.fromPubDev ? 'not fetched yet' : 'local or SDK'),
                      children: [
                        if (package.hasNewer) TextSpan(text: '  →  ${package.latest}', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)),
                        if (package.discontinued) TextSpan(text: '  discontinued', style: TextStyle(color: scheme.error)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  ),
                ],
              ),
            ),
            if (package.hasNewer && package.fromPubDev)
              IconButton(
                tooltip: package.canUpgrade ? 'Upgrade to ${package.upgradable}' : 'Upgrade to ${package.latest} (changes pubspec.yaml)',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: action ? () => widget.onRun(package.canUpgrade ? 'pub upgrade ${package.name}' : 'pub upgrade --major-versions ${package.name}') : null,
                icon: Icon(Icons.arrow_upward, color: action ? scheme.primary : null),
              ),
            if (package.fromPubDev || package.kind != PubKind.transitive)
              PopupMenuButton<VoidCallback>(
                tooltip: 'More',
                iconSize: 16,
                padding: EdgeInsets.zero,
                onSelected: (run) => run(),
                itemBuilder: (_) => [
                  if (package.fromPubDev && action) ...[
                    PopupMenuItem(height: 30, value: () => widget.onRun('pub upgrade ${package.name}'), child: const Text('Upgrade within its constraint')),
                    if (package.kind != PubKind.transitive)
                      PopupMenuItem(height: 30, value: () => widget.onRun('pub upgrade --major-versions ${package.name}'), child: const Text('Upgrade to the latest major version')),
                  ],
                  if (package.fromPubDev) PopupMenuItem(height: 30, value: () => openUrl('https://pub.dev/packages/${package.name}'), child: const Text('Open on pub.dev')),
                  if (package.kind != PubKind.transitive && action) PopupMenuItem(height: 30, value: () => unawaited(_remove(package)), child: const Text('Remove')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _searchResults(ColorScheme scheme) {
    final typed = _query.text.trim();
    final exact = isValidPubName(typed) && !_results.any((r) => r.name == typed);
    Widget result(PubSearchResult r) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: r.name,
                    children: [if (r.version != null) TextSpan(text: '  ${r.version}', style: TextStyle(fontSize: 11.5, color: scheme.outline))],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (r.description != null) Text(r.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(tooltip: 'Add as a dependency', iconSize: 17, visualDensity: VisualDensity.compact, onPressed: widget.busy ? null : () => _add(r.name), icon: const Icon(Icons.add)),
          PopupMenuButton<VoidCallback>(
            tooltip: 'More',
            iconSize: 16,
            padding: EdgeInsets.zero,
            onSelected: (run) => run(),
            itemBuilder: (_) => [
              if (!widget.busy) PopupMenuItem(height: 30, value: () => _add(r.name, dev: true), child: const Text('Add as a dev dependency')),
              PopupMenuItem(height: 30, value: () => openUrl('https://pub.dev/packages/${r.name}'), child: const Text('Open on pub.dev')),
            ],
          ),
        ],
      ),
    );

    return ListView(
      children: [
        if (_searching) const LinearProgressIndicator(minHeight: 2),
        if (_searchError case final error?) Padding(padding: const EdgeInsets.all(12), child: Text(error, style: TextStyle(fontSize: 12.5, color: scheme.error))),
        if (exact) result(PubSearchResult(typed)),
        for (final r in _results) result(r),
        if (!_searching && _searchError == null && _results.isEmpty && !exact)
          Padding(padding: const EdgeInsets.all(12), child: Text('No packages found.', style: TextStyle(fontSize: 12.5, color: scheme.outline))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!_hasPubspec) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('This folder has no pubspec.yaml.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: scheme.outline)),
        ),
      );
    }
    List<PubPackage> ofKind(PubKind kind) => _packages.where((x) => x.kind == kind).toList()..sort((a, b) => a.name.compareTo(b.name));
    final direct = ofKind(PubKind.direct), dev = ofKind(PubKind.dev), transitive = ofKind(PubKind.transitive);
    final updates = [...direct, ...dev].where((x) => x.hasNewer && x.fromPubDev).length;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    updates == 0 ? 'Packages' : 'Packages  •  $updates to update',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(tooltip: 'pub get', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: widget.busy ? null : () => widget.onRun('pub get'), icon: const Icon(Icons.download_outlined)),
                IconButton(tooltip: 'pub upgrade', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: widget.busy ? null : () => widget.onRun('pub upgrade'), icon: const Icon(Icons.upgrade)),
                IconButton(tooltip: 'Check again', iconSize: 16, visualDensity: VisualDensity.compact, onPressed: _checking ? null : _reload, icon: const Icon(Icons.refresh)),
                PopupMenuButton<String>(
                  tooltip: 'More pub commands',
                  iconSize: 16,
                  padding: EdgeInsets.zero,
                  enabled: !widget.busy,
                  onSelected: (value) => value.isEmpty ? widget.onSort() : widget.onRun(value),
                  itemBuilder: (_) => const [
                    PopupMenuItem(height: 30, value: '', child: Text('Sort pubspec.yaml A–Z')),
                    PopupMenuDivider(),
                    PopupMenuItem(height: 30, value: 'pub upgrade --major-versions', child: Text('Upgrade all to latest major versions')),
                    PopupMenuItem(height: 30, value: 'pub upgrade --tighten', child: Text('Upgrade and tighten constraints')),
                    PopupMenuItem(height: 30, value: 'pub downgrade', child: Text('Downgrade to the lowest allowed')),
                    PopupMenuDivider(),
                    PopupMenuItem(height: 30, value: 'pub outdated', child: Text('Show outdated report')),
                    PopupMenuItem(height: 30, value: 'pub deps', child: Text('Show dependency tree')),
                    PopupMenuItem(height: 30, value: 'pub cache repair', child: Text('Repair the package cache')),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
            child: TextField(
              controller: _query,
              onChanged: _onQuery,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search pub.dev to add a package',
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                prefixIcon: const Icon(Icons.search, size: 15),
                prefixIconConstraints: const BoxConstraints.tightFor(width: 28, height: 28),
                isDense: true,
              ),
            ),
          ),
          if (_checking) const LinearProgressIndicator(minHeight: 2),
          if (_checkFailed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Text("Couldn't check for updates. Are you online, and does pub get pass?", style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            ),
          Expanded(
            child: _query.text.trim().isNotEmpty
                ? _searchResults(scheme)
                : ListView(
                    children: [
                      if (direct.isNotEmpty) _heading('Dependencies (${direct.length})', scheme),
                      for (final x in direct) _row(x, scheme),
                      if (dev.isNotEmpty) _heading('Dev dependencies (${dev.length})', scheme),
                      for (final x in dev) _row(x, scheme),
                      if (transitive.isNotEmpty)
                        _heading('Pulled in by others (${transitive.length})', scheme, onTap: () => setState(() => _showTransitive = !_showTransitive), open: _showTransitive),
                      if (_showTransitive)
                        for (final x in transitive) _row(x, scheme),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
