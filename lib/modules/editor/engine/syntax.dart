import 'package:flutter/painting.dart';

import '../../../core/theme.dart';

enum TokenKind { keyword, control, type, function, string, number, comment, annotation, tag }

class LanguageSpec {
  const LanguageSpec({
    this.lineComment,
    this.blockComment,
    this.quotes = const ['"', "'"],
    this.tripleQuotes = false,
    this.keywords = const {},
    this.control = const {},
    this.caseSensitive = true,
    this.capitalizedAreTypes = true,
    this.annotationMark,
    this.markup = false,
    this.keyValue = false,
    this.markdown = false,
    this.dollarVariables = false,
  });

  final String? lineComment;
  final (String, String)? blockComment;
  final List<String> quotes;
  final bool tripleQuotes;
  final Set<String> keywords, control;
  final bool caseSensitive, capitalizedAreTypes;
  final String? annotationMark;

  /// Tags instead of code: XML, HTML.
  final bool markup;

  /// `key: value` or `key = value` lines: YAML, properties, TOML.
  final bool keyValue;
  final bool markdown;
  final bool dollarVariables;
}

const _dart = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  tripleQuotes: true,
  annotationMark: '@',
  keywords: {
    'abstract', 'as', 'async', 'await', 'base', 'class', 'const', 'covariant', 'deferred', 'dynamic', 'enum', 'export', 'extends', 'extension', 'external', 'factory', 'false', 'final', 'Function', 'get', 'hide', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new', 'null', 'of', 'on', 'operator', 'part', 'required', 'sealed', 'set', 'show', 'static', 'super', 'sync', 'this', 'true', 'type', 'typedef', 'var', 'void', 'when', 'with', 'yield',
  },
  control: {'assert', 'break', 'case', 'catch', 'continue', 'default', 'do', 'else', 'finally', 'for', 'if', 'rethrow', 'return', 'switch', 'throw', 'try', 'while'},
);

const _cLike = {'break', 'case', 'catch', 'continue', 'default', 'do', 'else', 'finally', 'for', 'if', 'return', 'switch', 'throw', 'try', 'while'};

const _kotlin = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  tripleQuotes: true,
  annotationMark: '@',
  quotes: ['"', "'"],
  keywords: {'abstract', 'as', 'by', 'class', 'companion', 'const', 'constructor', 'data', 'enum', 'false', 'final', 'fun', 'get', 'import', 'in', 'init', 'inline', 'interface', 'internal', 'is', 'lateinit', 'null', 'object', 'open', 'operator', 'override', 'package', 'private', 'protected', 'public', 'sealed', 'set', 'super', 'suspend', 'this', 'true', 'typealias', 'val', 'var', 'vararg', 'where'},
  control: {'break', 'catch', 'continue', 'do', 'else', 'finally', 'for', 'if', 'return', 'throw', 'try', 'when', 'while'},
);

const _java = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  annotationMark: '@',
  keywords: {'abstract', 'boolean', 'byte', 'char', 'class', 'const', 'double', 'enum', 'extends', 'false', 'final', 'float', 'implements', 'import', 'instanceof', 'int', 'interface', 'long', 'native', 'new', 'null', 'package', 'private', 'protected', 'public', 'short', 'static', 'super', 'synchronized', 'this', 'throws', 'transient', 'true', 'var', 'void', 'volatile'},
  control: _cLike,
);

const _swift = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  tripleQuotes: true,
  annotationMark: '@',
  quotes: ['"'],
  keywords: {'as', 'associatedtype', 'async', 'await', 'class', 'convenience', 'deinit', 'didSet', 'enum', 'extension', 'false', 'fileprivate', 'final', 'func', 'get', 'import', 'init', 'inout', 'internal', 'is', 'lazy', 'let', 'mutating', 'nil', 'open', 'override', 'private', 'protocol', 'public', 'required', 'self', 'set', 'static', 'struct', 'subscript', 'super', 'true', 'typealias', 'var', 'weak', 'willSet'},
  control: {'break', 'case', 'catch', 'continue', 'default', 'defer', 'do', 'else', 'fallthrough', 'for', 'guard', 'if', 'repeat', 'return', 'switch', 'throw', 'throws', 'try', 'where', 'while'},
);

const _cpp = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  annotationMark: '#',
  keywords: {'auto', 'bool', 'char', 'class', 'const', 'constexpr', 'delete', 'double', 'enum', 'explicit', 'extern', 'false', 'float', 'friend', 'inline', 'int', 'long', 'namespace', 'new', 'noexcept', 'nullptr', 'operator', 'override', 'private', 'protected', 'public', 'short', 'signed', 'sizeof', 'static', 'struct', 'template', 'this', 'true', 'typedef', 'typename', 'union', 'unsigned', 'using', 'virtual', 'void', 'volatile'},
  control: _cLike,
);

const _javascript = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  quotes: ['"', "'", '`'],
  keywords: {'async', 'await', 'class', 'const', 'delete', 'export', 'extends', 'false', 'from', 'function', 'import', 'in', 'instanceof', 'let', 'new', 'null', 'of', 'static', 'super', 'this', 'true', 'typeof', 'undefined', 'var', 'void', 'yield'},
  control: _cLike,
);

const _css = LanguageSpec(blockComment: ('/*', '*/'), keyValue: true, capitalizedAreTypes: false);
const _json = LanguageSpec(quotes: ['"'], keywords: {'true', 'false', 'null'}, capitalizedAreTypes: false);
const _yaml = LanguageSpec(lineComment: '#', keyValue: true, keywords: {'true', 'false', 'null', 'yes', 'no'}, capitalizedAreTypes: false);
const _properties = LanguageSpec(lineComment: '#', keyValue: true, keywords: {'true', 'false'}, capitalizedAreTypes: false);
const _xml = LanguageSpec(blockComment: ('<!--', '-->'), markup: true, capitalizedAreTypes: false);
const _markdown = LanguageSpec(markdown: true, quotes: [], capitalizedAreTypes: false);
const _gradle = LanguageSpec(
  lineComment: '//',
  blockComment: ('/*', '*/'),
  tripleQuotes: true,
  keywords: {'apply', 'def', 'false', 'implementation', 'import', 'new', 'null', 'plugins', 'true', 'val', 'var'},
  control: {'else', 'for', 'if', 'return', 'while'},
);
const _bash = LanguageSpec(
  lineComment: '#',
  capitalizedAreTypes: false,
  dollarVariables: true,
  keywords: {'alias', 'cd', 'echo', 'export', 'function', 'local', 'readonly', 'set', 'source', 'unset'},
  control: {'case', 'do', 'done', 'elif', 'else', 'esac', 'exit', 'fi', 'for', 'if', 'in', 'return', 'then', 'until', 'while'},
);
const _powershell = LanguageSpec(
  lineComment: '#',
  blockComment: ('<#', '#>'),
  caseSensitive: false,
  capitalizedAreTypes: false,
  dollarVariables: true,
  keywords: {'class', 'enum', 'false', 'function', 'module', 'null', 'param', 'true'},
  control: {'break', 'catch', 'continue', 'do', 'else', 'elseif', 'exit', 'finally', 'for', 'foreach', 'if', 'in', 'return', 'switch', 'throw', 'try', 'until', 'while'},
);

const _byExtension = <String, LanguageSpec>{
  '.dart': _dart,
  '.yaml': _yaml,
  '.yml': _yaml,
  '.json': _json,
  '.arb': _json,
  '.xml': _xml,
  '.html': _xml,
  '.plist': _xml,
  '.gradle': _gradle,
  '.kt': _kotlin,
  '.kts': _kotlin,
  '.java': _java,
  '.swift': _swift,
  '.c': _cpp,
  '.h': _cpp,
  '.cc': _cpp,
  '.cpp': _cpp,
  '.md': _markdown,
  '.sh': _bash,
  '.ps1': _powershell,
  '.properties': _properties,
  '.ini': _properties,
  '.toml': _properties,
  '.js': _javascript,
  '.ts': _javascript,
  '.css': _css,
};

LanguageSpec? languageForExtension(String extension) => _byExtension[extension.toLowerCase()];

/// Where a line starts inside something that began on an earlier one.
class LexState {
  const LexState.code() : blockDepth = 0, tripleQuote = null;
  const LexState.block(this.blockDepth) : tripleQuote = null;
  const LexState.triple(String this.tripleQuote) : blockDepth = 0;

  final int blockDepth;
  final String? tripleQuote;

  bool same(LexState other) => blockDepth == other.blockDepth && tripleQuote == other.tripleQuote;
}

class Token {
  const Token(this.start, this.end, this.kind);

  final int start, end;
  final TokenKind kind;
}

final _identStart = RegExp(r'[A-Za-z_$]');
final _ident = RegExp(r'[A-Za-z0-9_$]');
final _digit = RegExp(r'[0-9]');
final _number = RegExp(r'0[xX][0-9a-fA-F_]+|[0-9][0-9_]*(\.[0-9]+)?([eE][+-]?[0-9]+)?[a-zA-Z]?');
final _keyName = RegExp(r'^\s*(- )?([A-Za-z0-9_.\-"]+)\s*[:=]');
final _dollarVar = RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_:]*\}?');
final _tag = RegExp(r'</?[A-Za-z_][^\s>/]*|/?>');
final _attribute = RegExp(r'[A-Za-z_:][A-Za-z0-9_:.\-]*(?==)');
final _mdHeading = RegExp(r'^#{1,6} .*');
final _mdCode = RegExp(r'`[^`]+`');
final _mdBold = RegExp(r'\*\*[^*]+\*\*');
final _mdLink = RegExp(r'\[[^\]]+\]\([^)]+\)');

/// Reads one line. What's left open, a block comment or a long string, comes back for the next one.
(List<Token>, LexState) tokenizeLine(String text, LanguageSpec spec, LexState start) {
  if (spec.markdown) return (_markdownTokens(text), const LexState.code());
  final tokens = <Token>[];
  var i = 0;
  var state = start;

  final block = spec.blockComment;
  if (spec.keyValue && state.blockDepth == 0) {
    final m = _keyName.firstMatch(text);
    if (m != null) {
      final at = text.indexOf(m[2]!, m.start);
      tokens.add(Token(at, at + m[2]!.length, TokenKind.type));
      i = at + m[2]!.length;
    }
  }
  while (i < text.length) {
    if (state.blockDepth > 0) {
      final end = text.indexOf(block!.$2, i);
      if (end < 0) {
        tokens.add(Token(i, text.length, TokenKind.comment));
        return (tokens, state);
      }
      tokens.add(Token(i, end + block.$2.length, TokenKind.comment));
      i = end + block.$2.length;
      state = const LexState.code();
      continue;
    }
    if (state.tripleQuote != null) {
      final quote = state.tripleQuote!;
      final end = text.indexOf(quote, i);
      if (end < 0) {
        tokens.add(Token(i, text.length, TokenKind.string));
        return (tokens, state);
      }
      tokens.add(Token(i, end + 3, TokenKind.string));
      i = end + 3;
      state = const LexState.code();
      continue;
    }
    final c = text[i];
    if (block != null && text.startsWith(block.$1, i)) {
      state = const LexState.block(1);
      final end = text.indexOf(block.$2, i + block.$1.length);
      if (end < 0) {
        tokens.add(Token(i, text.length, TokenKind.comment));
        return (tokens, state);
      }
      tokens.add(Token(i, end + block.$2.length, TokenKind.comment));
      i = end + block.$2.length;
      state = const LexState.code();
      continue;
    }
    if (spec.lineComment != null && text.startsWith(spec.lineComment!, i)) {
      tokens.add(Token(i, text.length, TokenKind.comment));
      return (tokens, state);
    }
    if (spec.markup) {
      final tag = _tag.matchAsPrefix(text, i);
      if (tag != null) {
        tokens.add(Token(i, tag.end, TokenKind.tag));
        i = tag.end;
        continue;
      }
      final attribute = _attribute.matchAsPrefix(text, i);
      if (attribute != null) {
        tokens.add(Token(i, attribute.end, TokenKind.type));
        i = attribute.end;
        continue;
      }
    }
    if (spec.quotes.contains(c)) {
      final triple = c * 3;
      if (spec.tripleQuotes && text.startsWith(triple, i)) {
        final end = text.indexOf(triple, i + 3);
        if (end < 0) {
          tokens.add(Token(i, text.length, TokenKind.string));
          return (tokens, LexState.triple(triple));
        }
        tokens.add(Token(i, end + 3, TokenKind.string));
        i = end + 3;
        continue;
      }
      final raw = i > 0 && text[i - 1] == 'r';
      var j = i + 1;
      while (j < text.length && text[j] != c) {
        j += !raw && text[j] == r'\' ? 2 : 1;
      }
      final end = j < text.length ? j + 1 : text.length;
      tokens.add(Token(i, end, TokenKind.string));
      i = end;
      continue;
    }
    if (spec.annotationMark != null && text.startsWith(spec.annotationMark!, i) && i + 1 < text.length && _identStart.hasMatch(text[i + 1])) {
      var j = i + 1;
      while (j < text.length && _ident.hasMatch(text[j])) {
        j++;
      }
      tokens.add(Token(i, j, TokenKind.annotation));
      i = j;
      continue;
    }
    if (spec.dollarVariables && c == r'$') {
      final m = _dollarVar.matchAsPrefix(text, i);
      if (m != null) {
        tokens.add(Token(i, m.end, TokenKind.type));
        i = m.end;
        continue;
      }
    }
    if (_digit.hasMatch(c)) {
      final m = _number.matchAsPrefix(text, i)!;
      tokens.add(Token(i, m.end, TokenKind.number));
      i = m.end;
      continue;
    }
    if (_identStart.hasMatch(c)) {
      var j = i + 1;
      while (j < text.length && _ident.hasMatch(text[j])) {
        j++;
      }
      final word = text.substring(i, j);
      final key = spec.caseSensitive ? word : word.toLowerCase();
      final kind = spec.control.contains(key)
          ? TokenKind.control
          : spec.keywords.contains(key)
          ? TokenKind.keyword
          : (spec.capitalizedAreTypes && word[0] == word[0].toUpperCase() && word[0] != '_' && word[0] != r'$')
          ? TokenKind.type
          : (j < text.length && text[j] == '(' && spec.capitalizedAreTypes)
          ? TokenKind.function
          : null;
      if (kind != null) tokens.add(Token(i, j, kind));
      i = j;
      continue;
    }
    i++;
  }
  return (tokens, state);
}

List<Token> _markdownTokens(String text) {
  if (_mdHeading.hasMatch(text)) return [Token(0, text.length, TokenKind.keyword)];
  final tokens = [
    for (final m in _mdCode.allMatches(text)) Token(m.start, m.end, TokenKind.string),
    for (final m in _mdBold.allMatches(text)) Token(m.start, m.end, TokenKind.control),
    for (final m in _mdLink.allMatches(text)) Token(m.start, m.end, TokenKind.function),
  ]..sort((a, b) => a.start - b.start);
  final kept = <Token>[];
  var at = 0;
  for (final t in tokens) {
    if (t.start >= at) {
      kept.add(t);
      at = t.end;
    }
  }
  return kept;
}

Color colorOf(TokenKind kind, SyntaxColors syntax) => switch (kind) {
  TokenKind.keyword => syntax.keyword,
  TokenKind.control => syntax.control,
  TokenKind.type || TokenKind.tag => syntax.type,
  TokenKind.function || TokenKind.annotation => syntax.function,
  TokenKind.string => syntax.string,
  TokenKind.number => syntax.number,
  TokenKind.comment => syntax.comment,
};

/// One line as styled text. The base style is the span's own, so everything else inherits from it.
TextSpan spanForLine(String text, List<Token> tokens, SyntaxColors syntax, TextStyle base) {
  final children = <TextSpan>[];
  var at = 0;
  for (final t in tokens) {
    if (t.start > at) children.add(TextSpan(text: text.substring(at, t.start)));
    final end = t.end.clamp(0, text.length);
    children.add(TextSpan(text: text.substring(t.start, end), style: TextStyle(color: colorOf(t.kind, syntax))));
    at = end;
  }
  if (at < text.length) children.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: children);
}

/// A snippet of code as styled text, for docs and hover cards.
TextSpan highlightSnippet(String code, String extension, SyntaxColors syntax, TextStyle base) {
  final spec = languageForExtension(extension);
  if (spec == null) return TextSpan(text: code, style: base);
  var state = const LexState.code();
  final lines = code.split('\n');
  final children = <TextSpan>[];
  for (final (i, line) in lines.indexed) {
    final (tokens, next) = tokenizeLine(line, spec, state);
    state = next;
    children.add(spanForLine(line, tokens, syntax, base));
    if (i + 1 < lines.length) children.add(const TextSpan(text: '\n'));
  }
  return TextSpan(style: base, children: children);
}
