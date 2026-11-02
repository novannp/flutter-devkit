import 'dart:io';

import 'package:path/path.dart' as p;

/// A package a project pulls from git.
class CoreDep {
  const CoreDep({required this.name, this.url});

  final String name;
  final String? url;

  /// Repo folder name; pub caches it as `<repo>-<hash>`.
  String? get repo => url?.split(RegExp(r'[/:]')).last.replaceFirst(RegExp(r'\.git$'), '');
}

class CoreDeps {
  static File _pubspec(String project) => File(p.join(project, 'pubspec.yaml'));

  /// Lines of the `  name:` block under dependencies, as [start, end) indexes.
  static (int, int)? _block(List<String> lines, String name) {
    final start = lines.indexWhere((l) => RegExp('^  $name:\\s*\$').hasMatch(l));
    if (start < 0) return null;
    var end = start + 1;
    // Block continues while lines are indented deeper (comments like "#    path:" included).
    while (end < lines.length && (lines[end].startsWith('   ') || RegExp(r'^#\s{3,}').hasMatch(lines[end]))) {
      end++;
    }
    return (start, end);
  }

  /// Packages the project pulls from git, the ones teams usually share and pin by branch.
  static Future<List<String>> gitPackages(String project) async {
    final lines = (await _pubspec(project).readAsString()).split('\n');
    return {
      for (final m in lines.map(RegExp(r'^  (\w+):\s*$').firstMatch).nonNulls)
        if (_block(lines, m[1]!) case (final s, final e))
          if (lines.sublist(s, e).any((l) => RegExp(r'^\s+git:').hasMatch(l))) m[1]!,
    }.toList();
  }

  static Future<List<CoreDep>> read(String project, List<String> names) async {
    final lines = (await _pubspec(project).readAsString()).split('\n');
    return [
      for (final n in names)
        if (_block(lines, n) case (final s, final e))
          () {
            final block = lines.sublist(s, e).where((l) => !l.trimLeft().startsWith('#')).join('\n');
            return CoreDep(name: n, url: RegExp(r'(?:url|git):[ \t]*(\S+)').firstMatch(block)?[1]);
          }(),
    ];
  }
}
