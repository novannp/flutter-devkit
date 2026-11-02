import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'dart_settings.dart';
import 'engine/code_editor.dart';
import 'engine/snippet.dart';
import 'lsp_client.dart';

const _maxFileBytes = 20 * 1024 * 1024;

const _languageIds = {'.dart': 'dart', '.yaml': 'yaml', '.yml': 'yaml'};

/// Folders that only hold generated output, skipped by quick open and find in files.
const skippedFolders = {'build', '.dart_tool', '.git', '.fvm', '.idea', '.gradle', 'node_modules', 'Pods'};

class Diagnostic {
  const Diagnostic(this.path, this.line, this.column, this.endLine, this.endColumn, this.severity, this.message, this.code, this.raw);

  final String path;
  final int line, column, endLine, endColumn;

  /// 1 error, 2 warning, 3 info, 4 hint (LSP values).
  final int severity;
  final String message;
  final String? code;

  /// As the server sent it; code actions need it back unchanged.
  final Map<String, dynamic> raw;

  factory Diagnostic.fromLsp(String path, Map<String, dynamic> d) {
    final range = d['range'] as Map;
    final start = range['start'] as Map, end = range['end'] as Map;
    return Diagnostic(
      path,
      start['line'] as int,
      start['character'] as int,
      end['line'] as int,
      end['character'] as int,
      d['severity'] as int? ?? 1,
      d['message'] as String? ?? '',
      d['code']?.toString(),
      d,
    );
  }
}

/// LSP sends docs as either a plain string or a `{kind, value}` object.
String? lspMarkup(Object? value) {
  final text = value is Map ? value['value'] as String? : value as String?;
  return text == null || text.trim().isEmpty ? null : text;
}

class SignatureInfo {
  const SignatureInfo(this.label, this.activeStart, this.activeEnd, this.documentation);

  /// From a `textDocument/signatureHelp` answer; null when the caret isn't inside a call.
  static SignatureInfo? fromLsp(Object? result) {
    if (result is! Map) return null;
    final signatures = (result['signatures'] as List?) ?? const [];
    if (signatures.isEmpty) return null;
    final sig = signatures[(result['activeSignature'] as int? ?? 0).clamp(0, signatures.length - 1)] as Map;
    final label = sig['label'] as String? ?? '';
    final params = (sig['parameters'] as List?) ?? const [];
    final index = sig['activeParameter'] as int? ?? result['activeParameter'] as int? ?? 0;
    final active = index < params.length ? (params[index] as Map)['label'] as String? : null;
    final start = active == null ? -1 : label.indexOf(active);
    return SignatureInfo(label, start < 0 ? 0 : start, start < 0 ? 0 : start + active!.length, lspMarkup(sig['documentation']));
  }

  final String label;
  final int activeStart, activeEnd;
  final String? documentation;
}

class CompletionEntry {
  const CompletionEntry(this.raw);

  final Map<String, dynamic> raw;

  String get label => raw['label'] as String? ?? '';
  String get filter => raw['filterText'] as String? ?? label;
  String? get detail => (raw['labelDetails'] as Map?)?['description'] as String? ?? raw['detail'] as String?;

  /// The parameters, for showing next to the name.
  String get signature => (raw['labelDetails'] as Map?)?['detail'] as String? ?? '';

  String? get documentation => lspMarkup(raw['documentation']);
  int get kind => raw['kind'] as int? ?? 1;
  String get sortText => raw['sortText'] as String? ?? label;
}

/// Prefix matches first, then camelCase/subsequence matches, in the server's order.
List<CompletionEntry> filterCompletions(List<CompletionEntry> items, String input, {int limit = 60}) {
  final q = input.toLowerCase();
  final prefix = <CompletionEntry>[], fuzzy = <CompletionEntry>[];
  for (final item in items) {
    final f = item.filter.toLowerCase();
    if (f.startsWith(q)) {
      prefix.add(item);
    } else if (_isSubsequence(q, f)) {
      fuzzy.add(item);
    }
  }
  int bySort(CompletionEntry a, CompletionEntry b) => a.sortText.compareTo(b.sortText);
  prefix.sort(bySort);
  // The server sorts snippets last, which a long list would cut off before they're ever seen.
  final snippets = prefix.where((c) => c.kind == 15).toList();
  prefix
    ..removeWhere((c) => c.kind == 15)
    ..insertAll(min(3, prefix.length), snippets);
  return [...prefix, ...fuzzy..sort(bySort)].take(limit).toList();
}

bool _isSubsequence(String q, String s) {
  var i = 0;
  for (var j = 0; j < s.length && i < q.length; j++) {
    if (s.codeUnitAt(j) == q.codeUnitAt(i)) i++;
  }
  return i == q.length;
}

/// Applies LSP text edits to [text]; line endings stay as they are.
String applyTextEdits(String text, List<Map<String, dynamic>> edits) {
  final lineStarts = [0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
  }
  int offset(Map pos) {
    final line = pos['line'] as int;
    if (line >= lineStarts.length) return text.length;
    return (lineStarts[line] + (pos['character'] as int)).clamp(0, text.length);
  }

  // Back to front, so earlier offsets stay valid. The stable sort keeps same-position inserts in order.
  final resolved = [
    for (final (i, e) in edits.indexed)
      (i, offset((e['range'] as Map)['start'] as Map), offset((e['range'] as Map)['end'] as Map), e['newText'] as String),
  ]..sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : b.$1.compareTo(a.$1));
  var out = text;
  for (final (_, start, end, newText) in resolved) {
    out = out.replaceRange(start, end, newText);
  }
  return out;
}

final _librarySource = RegExp(r'[\\/](Pub[\\/]Cache|\.pub-cache|fvm[\\/]versions|flutter[\\/](packages|bin[\\/]cache))[\\/]');

/// Code from the SDK or the pub cache: readable by Go to Definition, but an edit would change every project.
bool isLibrarySource(String path) => _librarySource.hasMatch(path);

class DocSymbol {
  const DocSymbol(this.name, this.kind, this.startLine, this.startColumn, this.endLine, this.endColumn, this.line, this.column, this.children);

  factory DocSymbol.fromLsp(Map<String, dynamic> m) {
    Map pos(String range, String end) => (m[range] as Map)[end] as Map;
    return DocSymbol(
      m['name'] as String? ?? '',
      m['kind'] as int? ?? 0,
      pos('range', 'start')['line'] as int,
      pos('range', 'start')['character'] as int,
      pos('range', 'end')['line'] as int,
      pos('range', 'end')['character'] as int,
      pos('selectionRange', 'start')['line'] as int,
      pos('selectionRange', 'start')['character'] as int,
      [for (final c in (m['children'] as List?) ?? const []) DocSymbol.fromLsp((c as Map).cast<String, dynamic>())],
    );
  }

  final String name;
  final int kind;
  final int startLine, startColumn, endLine, endColumn;

  /// Where the name itself is, for jumping to it.
  final int line, column;
  final List<DocSymbol> children;

  bool contains(int atLine, int atColumn) =>
      (atLine > startLine || (atLine == startLine && atColumn >= startColumn)) &&
      (atLine < endLine || (atLine == endLine && atColumn <= endColumn));
}

/// The symbols around a position, outermost first.
List<DocSymbol> symbolChainAt(List<DocSymbol> symbols, int line, int column) {
  final chain = <DocSymbol>[];
  var level = symbols;
  while (true) {
    final hit = level.where((s) => s.contains(line, column)).firstOrNull;
    if (hit == null) return chain;
    chain.add(hit);
    level = hit.children;
  }
}

class SemanticToken {
  const SemanticToken(this.start, this.end, this.type, this.modifiers);

  final int start, end;
  final String type;
  final Set<String> modifiers;
}

/// Reads LSP's relative encoding: five numbers per token, each position relative to the previous token.
Map<int, List<SemanticToken>> decodeSemanticTokens(List<dynamic> data, List<String> types, List<String> modifiers) {
  final lines = <int, List<SemanticToken>>{};
  var line = 0, column = 0;
  for (var i = 0; i + 4 < data.length; i += 5) {
    final deltaLine = data[i] as int;
    line += deltaLine;
    column = deltaLine == 0 ? column + (data[i + 1] as int) : data[i + 1] as int;
    final type = data[i + 3] as int;
    final bits = data[i + 4] as int;
    if (type >= types.length) continue;
    lines.putIfAbsent(line, () => []).add(
      SemanticToken(column, column + (data[i + 2] as int), types[type], {
        for (final (bit, name) in modifiers.indexed)
          if (bits & (1 << bit) != 0) name,
      }),
    );
  }
  return lines;
}

class EditorDocument extends ChangeNotifier {
  EditorDocument._(this.path, this.controller, this._saved, this._modified);

  final String path;
  final CodeLineEditingController controller;

  /// Lives with the document, so switching tabs keeps the scroll position.
  final scroll = CodeScrollController();
  String _saved;
  DateTime _modified;
  int version = 1;
  bool dirty = false;

  /// The file changed on disk while this tab had unsaved edits.
  bool changedOnDisk = false;

  var diagnostics = const <Diagnostic>[];
  Map<int, List<SemanticToken>> semantics = const {};
  List<DocSymbol> symbols = const [];

  void setSymbols(List<DocSymbol> value) {
    symbols = value;
    notifyListeners();
  }
  Timer? _sync;
  void Function()? _onSync;
  CodeLines? _lastLines;

  String get name => p.basename(path);
  String get uri => Uri.file(path).toString();
  String? get languageId => _languageIds[p.extension(path).toLowerCase()];

  static Future<EditorDocument> open(String path, {CodeLineSpanBuilder? spanBuilder}) async {
    final file = File(path);
    final length = await file.length();
    if (length > _maxFileBytes) throw const FileSystemException('File is too large to edit (over 20 MB)');
    final bytes = await file.readAsBytes();
    if (bytes.contains(0)) throw const FileSystemException('Binary file');
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const FileSystemException('Not a UTF-8 text file');
    }
    final crlf = text.contains('\r\n');
    final controller = CodeLineEditingController(
      codeLines: CodeLines.fromText(text),
      options: CodeLineOptions(lineBreak: crlf ? TextLineBreak.crlf : TextLineBreak.lf),
      spanBuilder: spanBuilder,
    );
    final doc = EditorDocument._(path, controller, text, await file.lastModified());
    doc._lastLines = controller.codeLines;
    controller.addListener(doc._onControllerChanged);
    return doc;
  }

  void _onControllerChanged() {
    if (identical(controller.codeLines, _lastLines) || controller.codeLines == _lastLines) return;
    _lastLines = controller.codeLines;
    _sync?.cancel();
    _sync = Timer(const Duration(milliseconds: 150), flush);
  }

  /// Sends pending edits to the analysis server and refreshes the dirty flag.
  void flush() {
    _sync?.cancel();
    _sync = null;
    final isDirty = controller.text != _saved;
    if (isDirty != dirty) {
      dirty = isDirty;
      notifyListeners();
    }
    _onSync?.call();
  }

  bool get hasPendingSync => _sync != null;

  void replaceAll(String text) {
    if (text == controller.text) return;
    final selection = controller.selection;
    controller.text = text;
    final line = selection.extentIndex.clamp(0, controller.lineCount - 1);
    final column = selection.extentOffset.clamp(0, controller.codeLines[line].length);
    controller.selection = CodeLineSelection.collapsed(index: line, offset: column);
    flush();
  }

  Future<void> save() async {
    final text = controller.text;
    await File(path).writeAsString(text, flush: true);
    _saved = text;
    _modified = await File(path).lastModified();
    changedOnDisk = false;
    dirty = false;
    notifyListeners();
  }

  /// Follows edits made outside the editor (a branch switch, a formatter). Unsaved work is never overwritten.
  Future<bool> reloadIfChanged() async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final modified = await file.lastModified();
    if (modified == _modified) return false;
    _modified = modified;
    final text = await file.readAsString();
    if (text == _saved) return false;
    if (dirty) {
      changedOnDisk = true;
      notifyListeners();
      return false;
    }
    _saved = text;
    replaceAll(text);
    return true;
  }

  @override
  void dispose() {
    _sync?.cancel();
    controller.removeListener(_onControllerChanged);
    controller.dispose();
    super.dispose();
  }
}

/// The server writes hover docs in Markdown; the card shows plain text.
class EditTarget {
  const EditTarget(this.path, this.line, this.column);

  final String path;
  final int line, column;
}

/// Open files and language features for one project folder.
/// One view of the split editor, with its own tabs. A file lives in one group at a time.
class EditorGroup {
  final docs = <EditorDocument>[];
  EditorDocument? active;

  /// Share of the width, against the other groups.
  double weight = 1;

  /// A tab just arrived. Its editor waits a frame, so the old view has let go of the document first.
  bool settling = false;
}

class EditorWorkspace extends ChangeNotifier {
  EditorWorkspace(this.root, {this.spanBuilderFor});

  final String root;
  final CodeLineSpanBuilder Function(String path)? spanBuilderFor;

  final documents = <EditorDocument>[];
  final groups = [EditorGroup()];
  late EditorGroup focused = groups.first;

  EditorDocument? get active => focused.active;

  EditorGroup? groupOf(EditorDocument doc) => groups.where((g) => g.docs.contains(doc)).firstOrNull;

  void focusGroup(EditorGroup group) {
    if (identical(focused, group)) return;
    focused = group;
    notifyListeners();
  }

  void moveTab(EditorGroup group, int from, int to) {
    group.docs.insert(to, group.docs.removeAt(from));
    notifyListeners();
  }

  /// Moves a tab to another group, or to a new one on the right when [target] is null.
  void moveToGroup(EditorDocument doc, EditorGroup? target) {
    final from = groupOf(doc);
    if (from == null || identical(from, target)) return;
    // A lone tab moved to a new group would only trade one view for another.
    if (target == null && from.docs.length < 2) return;
    final to = target ?? EditorGroup();
    if (target == null) groups.insert(groups.indexOf(from) + 1, to);
    _takeOut(from, doc);
    to.docs.add(doc);
    to.active = doc;
    to.settling = true;
    focused = to;
    notifyListeners();
  }

  void _takeOut(EditorGroup group, EditorDocument doc) {
    final i = group.docs.indexOf(doc);
    group.docs.removeAt(i);
    if (group.active == doc) group.active = group.docs.isEmpty ? null : group.docs[i.clamp(0, group.docs.length - 1)];
    if (group.docs.isEmpty && groups.length > 1) {
      final at = groups.indexOf(group);
      groups.removeAt(at);
      if (identical(focused, group)) focused = groups[at.clamp(0, groups.length - 1)];
    }
  }
  final diagnostics = <String, List<Diagnostic>>{};

  LspClient? _lsp;
  Future<void>? _lspStart;
  final _opened = <String>{};
  bool analyzing = false;

  /// From launching the server until it first has answers. It can take a while and says nothing meanwhile.
  bool startingAnalyzer = false;
  LspClient? _starting;
  var _disposed = false;
  String? lspError;
  DartSettings dart = const DartSettings();
  bool get formatOnSave => dart.formatOnSave;
  final _semanticTimers = <EditorDocument, Timer>{};
  Timer? _diskPoll;
  StreamSubscription<Map<String, dynamic>>? _diagSub;
  StreamSubscription<bool>? _statusSub;

  /// Asks the page to move the caret after a jump, once the tab is showing.
  final revealRequests = StreamController<EditTarget>.broadcast();

  List<Diagnostic> get allDiagnostics {
    final all = [for (final l in diagnostics.values) ...l];
    all.sort((a, b) => a.severity != b.severity ? a.severity.compareTo(b.severity) : a.path.compareTo(b.path));
    return all;
  }

  int countOf(int severity) => diagnostics.values.fold(0, (n, l) => n + l.where((d) => d.severity == severity).length);

  /// Warms the server up before any Dart file is open, so the first one doesn't wait for it.
  Future<void> startAnalyzer() => _ensureLsp();

  Future<LspClient?> _ensureLsp() async {
    if (_lsp?.running == true) return _lsp;
    _lspStart ??= _startLsp();
    await _lspStart;
    return _lsp?.running == true ? _lsp : null;
  }

  void _analyzerAnswered() {
    if (!startingAnalyzer) return;
    startingAnalyzer = false;
    notifyListeners();
  }

  Future<void> _startLsp() async {
    startingAnalyzer = true;
    notifyListeners();
    final lsp = LspClient(root);
    lsp.onApplyEdit = applyWorkspaceEdit;
    lsp.dartConfig = () => dart.toServerConfig(root);
    lsp.onExit = () {
      _lspStart = null;
      _opened.clear();
      notifyListeners();
    };
    _diagSub = lsp.diagnostics.stream.listen(_onDiagnostics);
    _statusSub = lsp.analyzing.stream.listen((v) {
      analyzing = v;
      if (!v) startingAnalyzer = false;
      notifyListeners();
      if (!v) documents.forEach(_scheduleSemantics);
    });
    _starting = lsp;
    try {
      await lsp.start();
      if (_disposed) return;
      _lsp = lsp;
      lspError = null;
      // With no Dart file open yet there's nothing to analyze, so the server won't report anything.
      if (!documents.any((d) => d.languageId == 'dart')) startingAnalyzer = false;
    } catch (e) {
      if (_disposed) return;
      lspError = 'Dart analysis server failed to start: $e';
      startingAnalyzer = false;
    } finally {
      _starting = null;
    }
    notifyListeners();
  }

  Future<void> applyDartSettings(DartSettings settings) async {
    dart = settings;
    await settings.save(root);
    // The server asks for the configuration again after this.
    _lsp?.notify('workspace/didChangeConfiguration', {'settings': const <String, dynamic>{}});
    notifyListeners();
  }

  void _scheduleSemantics(EditorDocument doc) {
    _semanticTimers[doc]?.cancel();
    _semanticTimers[doc] = Timer(const Duration(milliseconds: 250), () => refreshSemantics(doc));
  }

  Future<void> refreshSemantics(EditorDocument doc) async {
    final lsp = _lsp;
    if (lsp == null || doc.languageId != 'dart' || !lsp.running) return;
    final version = doc.version;
    try {
      final result = await lsp.request('textDocument/semanticTokens/full', {
        'textDocument': {'uri': doc.uri},
      });
      // Positions from an older text would paint the wrong words; the newer edit has its own request coming.
      if (doc.version != version || result is! Map || !documents.contains(doc)) return;
      _analyzerAnswered();
      doc.semantics = decodeSemanticTokens(result['data'] as List, lsp.tokenTypes, lsp.tokenModifiers);
      doc.controller.forceRepaint();
      final symbols = await lsp.request('textDocument/documentSymbol', {
        'textDocument': {'uri': doc.uri},
      });
      if (doc.version != version || symbols is! List || !documents.contains(doc)) return;
      doc.setSymbols([
        for (final m in symbols.cast<Map>())
          if (m.containsKey('range')) DocSymbol.fromLsp(m.cast<String, dynamic>()),
      ]);
    } on Exception {
      // Colors are a nicety: the regex highlighting stays until the next edit.
    }
  }

  void _onDiagnostics(Map<String, dynamic> params) {
    final path = Uri.parse(params['uri'] as String).toFilePath();
    // Lints in someone else's package aren't this project's problems.
    if (isLibrarySource(path)) return;
    final list = [
      for (final d in (params['diagnostics'] as List).cast<Map<String, dynamic>>()) Diagnostic.fromLsp(path, d),
    ];
    if (list.isEmpty) {
      diagnostics.remove(path);
    } else {
      diagnostics[path] = list;
    }
    final doc = documentAt(path);
    if (doc != null) {
      doc.diagnostics = list;
      doc.controller.forceRepaint();
    }
    notifyListeners();
  }

  EditorDocument? documentAt(String path) =>
      documents.where((d) => p.equals(d.path, path)).firstOrNull;

  Future<EditorDocument> open(String path, {int? line, int? column}) async {
    var doc = documentAt(path);
    if (doc == null) {
      doc = await EditorDocument.open(path, spanBuilder: spanBuilderFor?.call(path));
      documents.add(doc);
      focused.docs.add(doc);
      doc.diagnostics = diagnostics[path] ?? const [];
      doc.addListener(notifyListeners);
      doc._onSync = () => _sendChange(doc!);
      _diskPoll ??= Timer.periodic(const Duration(seconds: 2), (_) => _checkDisk());
      if (doc.languageId != null) unawaited(_openOnServer(doc));
    }
    focused = groupOf(doc) ?? focused;
    focused.active = doc;
    notifyListeners();
    if (line != null) revealRequests.add(EditTarget(path, line, column ?? 0));
    return doc;
  }

  Future<void> _openOnServer(EditorDocument doc) async {
    final lsp = await _ensureLsp();
    if (lsp == null || !documents.contains(doc) || !_opened.add(doc.path)) return;
    lsp.notify('textDocument/didOpen', {
      'textDocument': {'uri': doc.uri, 'languageId': doc.languageId, 'version': doc.version, 'text': doc.controller.text},
    });
    // A file opened once analysis has settled gets no status change to wake its colors up.
    _scheduleSemantics(doc);
  }

  void _sendChange(EditorDocument doc) {
    if (!_opened.contains(doc.path)) return;
    doc.version++;
    _scheduleSemantics(doc);
    _lsp?.notify('textDocument/didChange', {
      'textDocument': {'uri': doc.uri, 'version': doc.version},
      'contentChanges': [
        {'text': doc.controller.text},
      ],
    });
  }

  Future<void> _checkDisk() async {
    for (final d in List.of(documents)) {
      try {
        await d.reloadIfChanged();
      } on FileSystemException {
        // Mid-write by another tool: the next tick reads it.
      }
    }
  }

  void activate(EditorDocument doc) {
    focused = groupOf(doc) ?? focused;
    focused.active = doc;
    notifyListeners();
  }

  Future<void> close(EditorDocument doc) async {
    final i = documents.indexOf(doc);
    if (i < 0) return;
    documents.removeAt(i);
    if (_opened.remove(doc.path)) {
      _lsp?.notify('textDocument/didClose', {
        'textDocument': {'uri': doc.uri},
      });
    }
    final group = groupOf(doc);
    if (group != null) _takeOut(group, doc);
    doc.removeListener(notifyListeners);
    notifyListeners();
    // After the tab's editor is gone from the tree.
    Timer(const Duration(milliseconds: 300), doc.dispose);
  }

  Future<void> save(EditorDocument doc) async {
    if (isLibrarySource(doc.path)) return;
    if (formatOnSave && doc.languageId == 'dart') {
      try {
        await format(doc);
      } on Exception {
        // Code that doesn't parse can't be formatted; it still gets saved.
      }
    }
    doc.flush();
    await doc.save();
    if (_opened.contains(doc.path)) {
      _lsp?.notify('textDocument/didSave', {
        'textDocument': {'uri': doc.uri},
      });
    }
  }

  Future<void> saveAll() async {
    for (final d in documents.where((d) => d.dirty).toList()) {
      await save(d);
    }
  }

  Map<String, dynamic> _position(EditorDocument doc, int line, int column) => {
    'textDocument': {'uri': doc.uri},
    'position': {'line': line, 'character': column},
  };

  Future<dynamic> _request(EditorDocument doc, String method, Object? params) async {
    if (doc.languageId == null) return null;
    final lsp = await _ensureLsp();
    if (lsp == null) return null;
    await _openOnServer(doc);
    if (doc.hasPendingSync) doc.flush();
    return lsp.request(method, params);
  }

  Future<List<CompletionEntry>> completion(EditorDocument doc, int line, int column) async {
    final r = await _request(doc, 'textDocument/completion', _position(doc, line, column));
    final items = r is Map ? r['items'] as List? : r as List?;
    return [for (final i in (items ?? const []).cast<Map>()) CompletionEntry(i.cast<String, dynamic>())];
  }

  /// Fills in the auto-import edit of a suggestion from a library that isn't imported yet.
  Future<CompletionEntry> resolveCompletion(EditorDocument doc, CompletionEntry entry) async {
    if (entry.raw['data'] == null) return entry;
    final r = await _request(doc, 'completionItem/resolve', entry.raw);
    return r is Map ? CompletionEntry(r.cast<String, dynamic>()) : entry;
  }

  Future<String?> documentationOf(EditorDocument doc, CompletionEntry entry) async =>
      entry.documentation ?? (await resolveCompletion(doc, entry)).documentation;

  Future<SignatureInfo?> signatureHelp(EditorDocument doc, int line, int column) async =>
      SignatureInfo.fromLsp(await _request(doc, 'textDocument/signatureHelp', _position(doc, line, column)));

  /// Hover Markdown at a position, or null when there's nothing to say.
  Future<String?> hover(EditorDocument doc, int line, int column) async {
    final r = await _request(doc, 'textDocument/hover', _position(doc, line, column));
    if (r is! Map) return null;
    return lspMarkup(r['contents']);
  }

  Future<EditTarget?> definition(EditorDocument doc, int line, int column) async {
    final r = await _request(doc, 'textDocument/definition', _position(doc, line, column));
    final loc = (r is List ? r.firstOrNull : r) as Map?;
    if (loc == null) return null;
    final uri = (loc['uri'] ?? loc['targetUri']) as String;
    final range = (loc['range'] ?? loc['targetSelectionRange']) as Map;
    final start = range['start'] as Map;
    return EditTarget(Uri.parse(uri).toFilePath(), start['line'] as int, start['character'] as int);
  }

  /// Locations with the text of their lines. An open tab's text wins, since it may not be saved yet.
  Future<List<SearchHit>> referenceHits(List<EditTarget> refs) async {
    final files = <String, List<String>>{};
    final hits = <SearchHit>[];
    for (final r in refs) {
      var lines = files[r.path];
      if (lines == null) {
        final open = documentAt(r.path);
        try {
          lines = open != null ? open.controller.text.split('\n') : await File(r.path).readAsLines();
        } on Exception {
          // A file that can't be read still gets its location listed.
          lines = const [];
        }
        files[r.path] = lines;
      }
      hits.add(SearchHit(r.path, r.line, r.column, lines.elementAtOrNull(r.line)?.trim() ?? ''));
    }
    return hits;
  }

  Future<List<EditTarget>> references(EditorDocument doc, int line, int column) async {
    final r = await _request(doc, 'textDocument/references', {
      ..._position(doc, line, column),
      'context': {'includeDeclaration': true},
    });
    return [
      for (final l in ((r as List?) ?? const []).cast<Map>())
        EditTarget(
          Uri.parse(l['uri'] as String).toFilePath(),
          ((l['range'] as Map)['start'] as Map)['line'] as int,
          ((l['range'] as Map)['start'] as Map)['character'] as int,
        ),
    ];
  }

  Future<void> format(EditorDocument doc) async {
    if (isLibrarySource(doc.path)) return;
    final edits = await _request(doc, 'textDocument/formatting', {
      'textDocument': {'uri': doc.uri},
      'options': {'tabSize': 2, 'insertSpaces': true},
    });
    if (edits is List && edits.isNotEmpty) {
      doc.replaceAll(applyTextEdits(doc.controller.text, edits.cast<Map<String, dynamic>>()));
    }
  }

  Future<void> rename(EditorDocument doc, int line, int column, String newName) async {
    final edit = await _request(doc, 'textDocument/rename', {..._position(doc, line, column), 'newName': newName});
    if (edit is Map) await applyWorkspaceEdit(edit.cast<String, dynamic>());
  }

  /// Quick fixes and refactors at a position, as raw LSP code actions.
  Future<List<Map<String, dynamic>>> codeActions(EditorDocument doc, int line, int column) async {
    final here = doc.diagnostics.where((d) => d.line <= line && line <= d.endLine).map((d) => d.raw).toList();
    final r = await _request(doc, 'textDocument/codeAction', {
      'textDocument': {'uri': doc.uri},
      'range': {
        'start': {'line': line, 'character': column},
        'end': {'line': line, 'character': column},
      },
      'context': {'diagnostics': here},
    });
    return [
      for (final a in ((r as List?) ?? const []).cast<Map>())
        if (a['title'] != null) a.cast<String, dynamic>(),
    ];
  }

  Future<void> runCodeAction(Map<String, dynamic> action) async {
    final edit = action['edit'] as Map?;
    if (edit != null) await applyWorkspaceEdit(edit.cast<String, dynamic>());
    final command = action['command'] as Map?;
    if (command != null) {
      await _lsp?.request('workspace/executeCommand', {'command': command['command'], 'arguments': command['arguments']});
    }
  }

  /// Applies edits to open tabs (undoable, unsaved) and straight to disk for other files.
  Future<void> applyWorkspaceEdit(Map<String, dynamic> edit) async {
    final byUri = <String, List<Map<String, dynamic>>>{};
    for (final c in ((edit['documentChanges'] as List?) ?? const []).cast<Map>()) {
      final td = c['textDocument'] as Map?;
      if (td != null) byUri.putIfAbsent(td['uri'] as String, () => []).addAll((c['edits'] as List).cast());
    }
    (edit['changes'] as Map?)?.forEach((uri, edits) {
      byUri.putIfAbsent(uri as String, () => []).addAll((edits as List).cast());
    });
    for (final MapEntry(key: uri, value: edits) in byUri.entries) {
      final path = Uri.parse(uri).toFilePath();
      final doc = documentAt(path);
      if (doc != null) {
        doc.replaceAll(applyTextEdits(doc.controller.text, edits));
      } else {
        final file = File(path);
        await file.writeAsString(applyTextEdits(await file.readAsString(), edits));
      }
    }
  }

  /// Applies a chosen completion: its text edit plus any auto-import. A snippet with stops to fill
  /// comes back as a session, for Tab to walk.
  SnippetSession? applyCompletion(EditorDocument doc, CompletionEntry entry, {required int line, required int start, required int end}) {
    final raw = entry.raw;
    final textEdit = raw['textEdit'] as Map?;
    var newText = (textEdit?['newText'] ?? raw['insertText'] ?? raw['label']) as String;
    ParsedSnippet? snippet;
    if (raw['insertTextFormat'] == 2) {
      newText = newText.replaceAll('\r\n', '\n');
      // Unless the server says it's as is, following lines take this line's indent.
      if (raw['insertTextMode'] != 1) {
        final current = doc.controller.codeLines[line].text;
        newText = newText.replaceAll('\n', '\n${current.substring(0, current.length - current.trimLeft().length)}');
      }
      snippet = parseSnippet(newText);
      newText = snippet.text;
    }
    final range = (textEdit?['range'] ?? textEdit?['insert']) as Map?;
    final sameLineStart = range == null ? start : ((range['start'] as Map)['character'] as int);
    // The server's range was computed before the last keystrokes, so its end can lag behind the caret.
    final main = {
      'range': {
        'start': {'line': line, 'character': sameLineStart},
        'end': {'line': line, 'character': end},
      },
      'newText': newText,
    };
    final extra = ((raw['additionalTextEdits'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final controller = doc.controller;
    final caretColumn = sameLineStart + newText.length;
    final addedLines = extra.fold<int>(0, (n, e) => n + '\n'.allMatches(e['newText'] as String).length);
    controller.text = applyTextEdits(controller.text, [main, ...extra]);
    SnippetSession? session;
    if (snippet != null) {
      final lines = controller.codeLines;
      var start = sameLineStart;
      for (var i = 0; i < line + addedLines; i++) {
        start += lines[i].length + 1;
      }
      session = SnippetSession(controller, start, snippet);
    } else {
      controller.selection = CodeLineSelection.collapsed(index: line + addedLines, offset: caretColumn);
    }
    doc.flush();
    return session?.active ?? false ? session : null;
  }

  @override
  void dispose() {
    for (final t in _semanticTimers.values) {
      t.cancel();
    }
    _disposed = true;
    _lsp?.onExit = null;
    _starting?.onExit = null;
    unawaited(_starting?.dispose());
    _diskPoll?.cancel();
    _diagSub?.cancel();
    _statusSub?.cancel();
    revealRequests.close();
    unawaited(_lsp?.dispose());
    for (final d in documents) {
      d.removeListener(notifyListeners);
      d.dispose();
    }
    super.dispose();
  }
}

/// One line that matches a project-wide search.
class SearchHit {
  const SearchHit(this.path, this.line, this.column, this.text);

  final String path;
  final int line, column;
  final String text;
}

/// Searches text files under [root], leaving out generated folders. Runs on another isolate to keep typing smooth.
Future<List<SearchHit>> searchInFiles(String root, String query, {int limit = 1000}) =>
    compute((_) => _search(root, query, limit), null);

List<SearchHit> _search(String root, String query, int limit) {
  final q = query.toLowerCase();
  final hits = <SearchHit>[];
  void walk(Directory dir) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in entries) {
      if (hits.length >= limit) return;
      if (e is Directory) {
        if (!skippedFolders.contains(p.basename(e.path))) walk(e);
      } else if (e is File) {
        try {
          if (e.lengthSync() > 2 * 1024 * 1024) continue;
          final bytes = e.readAsBytesSync();
          if (bytes.contains(0)) continue;
          final lines = utf8.decode(bytes).split('\n');
          for (final (i, l) in lines.indexed) {
            final c = l.toLowerCase().indexOf(q);
            if (c >= 0) hits.add(SearchHit(e.path, i, c, l.trimRight()));
          }
        } on Exception {
          // Unreadable or not UTF-8: not something to search.
        }
      }
    }
  }

  walk(Directory(root));
  return hits;
}

/// Every file under [root] outside generated folders, for quick open.
Future<List<String>> listProjectFiles(String root) => compute((_) {
  final files = <String>[];
  void walk(Directory dir) {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (e is Directory) {
          if (!skippedFolders.contains(p.basename(e.path))) walk(e);
        } else if (e is File) {
          files.add(e.path);
        }
      }
    } on FileSystemException {
      // Unreadable folders are skipped.
    }
  }

  walk(Directory(root));
  return files;
}, null);
