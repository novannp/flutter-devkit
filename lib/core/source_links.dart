import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'local_builds.dart';

final _ref = RegExp(
  r'''(package:[\w.]+/[^\s:()'"]+\.dart|file:///[^\s()'"]+?\.dart|(?<![\w/\\])lib[/\\][^\s:()'"]+\.dart)(?::(\d+)(?::(\d+))?)?''',
);

/// Maps `package:`, `file:///` and `lib/` references in logs to files in the configured Flutter projects.
class SourceResolver {
  SourceResolver._();

  static final instance = SourceResolver._();

  /// Project path → package name → its lib/ folder.
  Map<String, Map<String, String>>? _packages;
  List<FlutterProject> _projects = const [];
  DateTime _loaded = DateTime(0);

  // Re-read now and then: a branch switch or local override changes where packages point.
  Future<void> _load() async {
    if (_packages != null && DateTime.now().difference(_loaded) < const Duration(minutes: 1)) return;
    final all = <String, Map<String, String>>{};
    final projects = await scanFlutterProjects();
    for (final p in projects) {
      final packages = all[p.path] = {};
      final config = File('${p.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}package_config.json');
      if (!config.existsSync()) continue;
      try {
        final base = Uri.file(config.path);
        final j = jsonDecode(await config.readAsString()) as Map<String, dynamic>;
        for (final e in (j['packages'] as List).cast<Map<String, dynamic>>()) {
          var root = e['rootUri'] as String;
          if (!root.endsWith('/')) root += '/';
          final lib = base.resolve(root).resolve(e['packageUri'] as String? ?? 'lib/');
          packages[e['name'] as String] = lib.toFilePath();
        }
      } catch (_) {
        // A half-written config during `pub get` shouldn't break the others.
      }
    }
    _packages = all;
    _projects = projects;
    _loaded = DateTime.now();
  }

  /// Project folder of an installed app id, used as [resolve]'s preferred root.
  Future<String?> projectOf(String? appId) async {
    if (appId == null) return null;
    await _load();
    return _projects.where((p) => p.package == appId).firstOrNull?.path;
  }

  /// The local file for [ref], or null when it isn't in any known project. [root]'s
  /// packages win, since each app may pin a different branch of a shared package.
  Future<String?> resolve(String ref, {String? root}) async {
    if (ref.startsWith('file:///')) return Uri.parse(ref).toFilePath();
    await _load();
    final roots = [?root, for (final p in _projects) p.path];
    if (ref.startsWith('package:')) {
      final slash = ref.indexOf('/');
      final name = ref.substring('package:'.length, slash);
      for (final r in roots) {
        final dir = _packages![r]?[name];
        if (dir == null) continue;
        final path = '$dir${ref.substring(slash + 1)}'.replaceAll('/', Platform.pathSeparator);
        if (File(path).existsSync()) return path;
      }
      return null;
    }
    for (final r in roots) {
      final path = '$r${Platform.pathSeparator}${ref.replaceAll('/', Platform.pathSeparator)}';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  /// Opens the reference in VS Code at the line; returns an error message on failure.
  Future<String?> open(String ref, {int? line, int? column, String? root, String? appId}) async {
    final path = await resolve(ref, root: root ?? await projectOf(appId));
    if (path == null) return '$ref is not in your project folders';
    final target = [path, ?line, if (line != null) ?column].join(':');
    try {
      final r = await Process.run('code', ['-g', target], runInShell: true);
      if (r.exitCode == 0) return null;
    } catch (_) {}
    // No VS Code on PATH: at least open the file.
    await Process.run('cmd', ['/c', 'start', '', path]);
    return null;
  }
}

/// Text where Dart source references (`package:my_pkg/cart.dart:142:7`) open in VS Code on click.
class SourceLinkText extends StatefulWidget {
  const SourceLinkText(this.text, {super.key, this.style, this.maxLines, this.overflow, this.root, this.appId});

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  /// Project folder for relative `lib/...` paths, tried before the other projects.
  final String? root;

  /// App the line came from; its project's packages are preferred.
  final String? appId;

  @override
  State<SourceLinkText> createState() => _SourceLinkTextState();
}

class _SourceLinkTextState extends State<SourceLinkText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _open(RegExpMatch m) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final error = await SourceResolver.instance.open(
      m[1]!,
      line: int.tryParse(m[2] ?? ''),
      column: int.tryParse(m[3] ?? ''),
      root: widget.root,
      appId: widget.appId,
    );
    if (error != null) messenger?.showSnackBar(SnackBar(content: Text(error), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final matches = _ref.allMatches(widget.text).toList();
    if (matches.isEmpty) {
      return Text(widget.text, style: widget.style, maxLines: widget.maxLines, overflow: widget.overflow);
    }
    final link = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
    );
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in matches) {
      if (m.start > last) spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      final r = TapGestureRecognizer()..onTap = () => _open(m);
      _recognizers.add(r);
      spans.add(TextSpan(text: m[0], style: link, recognizer: r, mouseCursor: SystemMouseCursors.click));
      last = m.end;
    }
    if (last < widget.text.length) spans.add(TextSpan(text: widget.text.substring(last)));
    return Text.rich(
      TextSpan(style: widget.style, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
