const _closes = {'(': ')', '[': ']', '{': '}'};
const _opens = {')': '(', ']': '[', '}': '{'};

/// Every matched bracket mapped to its partner, as (line, column). Brackets in strings and comments don't count.
Map<(int, int), (int, int)> bracketPairs(List<String> lines) {
  final pairs = <(int, int), (int, int)>{};
  final stack = <(String, int, int)>[];
  var blockComment = 0;
  String? multiline;
  for (var l = 0; l < lines.length; l++) {
    final text = lines[l];
    var i = 0;
    while (i < text.length) {
      if (blockComment > 0) {
        if (text.startsWith('*/', i)) {
          blockComment--;
          i += 2;
        } else if (text.startsWith('/*', i)) {
          blockComment++;
          i += 2;
        } else {
          i++;
        }
        continue;
      }
      if (multiline != null) {
        final end = text.indexOf(multiline, i);
        if (end < 0) break;
        i = end + 3;
        multiline = null;
        continue;
      }
      if (text.startsWith('//', i)) break;
      if (text.startsWith('/*', i)) {
        blockComment++;
        i += 2;
        continue;
      }
      final c = text[i];
      if (c == "'" || c == '"') {
        final triple = c * 3;
        if (text.startsWith(triple, i)) {
          multiline = triple;
          i += 3;
          continue;
        }
        final raw = i > 0 && text[i - 1] == 'r';
        i++;
        while (i < text.length && text[i] != c) {
          i += !raw && text[i] == r'\' ? 2 : 1;
        }
        i++;
        continue;
      }
      if (_closes.containsKey(c)) {
        stack.add((c, l, i));
      } else if (_opens.containsKey(c)) {
        // A stray closer leaves the stack alone, so code mid-edit still matches around it.
        if (stack.isNotEmpty && stack.last.$1 == _opens[c]) {
          final open = stack.removeLast();
          pairs[(open.$2, open.$3)] = (l, i);
          pairs[(l, i)] = (open.$2, open.$3);
        }
      }
      i++;
    }
  }
  return pairs;
}

/// The pair the caret touches: the bracket right after it, else the one right before it.
((int, int), (int, int))? pairAtCaret(Map<(int, int), (int, int)> pairs, int line, int column) {
  for (final at in [(line, column), (line, column - 1)]) {
    final other = pairs[at];
    if (other != null) return (at, other);
  }
  return null;
}
