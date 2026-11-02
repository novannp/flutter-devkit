import 'package:path/path.dart' as p;

class FileMatch {
  const FileMatch(this.path, this.name, this.folder, this.score, this.nameHits, this.folderHits);

  final String path, name, folder;
  final int score;
  final Set<int> nameHits, folderHits;
}

const _separators = {'_', '-', '.', '/', r'\', ' '};
final _splitQuery = RegExp(r'[\s_\-./\\]+');

bool _isBoundary(String text, int i) {
  if (i == 0 || _separators.contains(text[i - 1])) return true;
  final c = text[i], before = text[i - 1];
  // camelCase: the "P" in onlinePayment.
  return c != c.toLowerCase() && before == before.toLowerCase();
}

/// Best way to find [token]'s letters, in order, inside [text]: word starts and runs of letters score highest.
(int, Set<int>)? _matchToken(String token, String text) {
  final lower = text.toLowerCase();
  var from = 0;
  for (final unit in token.codeUnits) {
    from = lower.indexOf(String.fromCharCode(unit), from);
    if (from < 0) return null;
    from++;
  }
  const none = -1 << 30;
  final n = text.length;
  final best = [for (var i = 0; i < token.length; i++) List.filled(n, none)];
  final prev = [for (var i = 0; i < token.length; i++) List.filled(n, -1)];
  for (var i = 0; i < token.length; i++) {
    for (var j = i; j < n; j++) {
      if (lower[j] != token[i]) continue;
      final own = 1 + (_isBoundary(text, j) ? 8 : 0);
      if (i == 0) {
        best[i][j] = own - (j > 8 ? 8 : j);
        continue;
      }
      for (var k = i - 1; k < j; k++) {
        if (best[i - 1][k] == none) continue;
        final gap = j - k - 1;
        final step = gap == 0 ? 6 : -(gap > 3 ? 3 : gap);
        final score = best[i - 1][k] + own + step;
        if (score > best[i][j]) {
          best[i][j] = score;
          prev[i][j] = k;
        }
      }
    }
  }
  var end = -1;
  for (var j = 0; j < n; j++) {
    if (best[token.length - 1][j] != none && (end < 0 || best[token.length - 1][j] > best[token.length - 1][end])) end = j;
  }
  if (end < 0) return null;
  final hits = <int>{};
  for (var i = token.length - 1, j = end; i >= 0; j = prev[i][j], i--) {
    hits.add(j);
  }
  return (best[token.length - 1][end], hits);
}

/// Scores one file against a query. Each word can land anywhere in the name or the folder, in any order.
FileMatch? matchFile(String query, String path, String root) {
  final tokens = query.toLowerCase().split(_splitQuery).where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) return null;
  final name = p.basename(path);
  final folder = p.relative(p.dirname(path), from: root);
  var score = 0;
  final nameHits = <int>{}, folderHits = <int>{};
  for (final token in tokens) {
    final inName = _matchToken(token, name);
    final inFolder = _matchToken(token, folder);
    if (inName == null && inFolder == null) return null;
    // A hit in the name is nearly always what was meant, so the folder only wins when the name has none.
    if (inName != null) {
      score += inName.$1 + 40;
      nameHits.addAll(inName.$2);
    } else {
      score += inFolder!.$1;
      folderHits.addAll(inFolder.$2);
    }
  }
  final stem = p.basenameWithoutExtension(name).toLowerCase().replaceAll(_splitQuery, '');
  if (stem == tokens.join()) score += 200;
  return FileMatch(path, name, folder, score, nameHits, folderHits);
}

List<FileMatch> rankFiles(List<String> files, String root, String query, {int limit = 50}) {
  final matches = [for (final f in files) ?matchFile(query, f, root)];
  matches.sort((a, b) {
    if (a.score != b.score) return b.score.compareTo(a.score);
    return a.path.length != b.path.length ? a.path.length.compareTo(b.path.length) : a.path.compareTo(b.path);
  });
  return matches.take(limit).toList();
}

/// Splits `name.dart:42` into the search text and the line to jump to (0-based).
(String, int?) splitLineSuffix(String query) {
  final m = RegExp(r'^(.*?):(\d+)(?::\d+)?\s*$').firstMatch(query);
  if (m == null) return (query, null);
  final line = int.parse(m[2]!);
  return (m[1]!, line > 0 ? line - 1 : 0);
}
