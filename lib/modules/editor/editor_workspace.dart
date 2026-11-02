import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';

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

class CompletionEntry {
  const CompletionEntry(this.raw);

  final Map<String, dynamic> raw;

  String get label => raw['label'] as String? ?? '';
  String get filter => raw['filterText'] as String? ?? label;
  String? get detail => raw['detail'] as String? ?? (raw['labelDetails'] as Map?)?['description'] as String?;
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
  return [...prefix..sort(bySort), ...fuzzy..sort(bySort)].take(limit).toList();
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
String plainHover(String markdown) => markdown
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('```'))
    .join('\n')
    .replaceAll(RegExp(r'[`*]'), '')
    .replaceAll(RegExp(r'\n{3,}'), '\n\n')
    .trim();

class EditTarget {
  const EditTarget(this.path, this.line, this.column);

  final String path;
  final int line, column;
}

/// Open files and language features for one project folder.
class EditorWorkspace extends ChangeNotifier {
  EditorWorkspace(this.root, {this.spanBuilderFor});

  final String root;
  final CodeLineSpanBuilder Function(String path)? spanBuilderFor;

  final documents = <EditorDocument>[];
  EditorDocument? active;
  final diagnostics = <String, List<Diagnostic>>{};

  LspClient? _lsp;
  Future<void>? _lspStart;
  final _opened = <String>{};
  bool analyzing = false;
  String? lspError;
  bool formatOnSave = true;
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

  // The server starts with the first Dart file, so browsing other files stays free of its memory use.
  Future<LspClient?> _ensureLsp() async {
    if (_lsp?.running == true) return _lsp;
    _lspStart ??= _startLsp();
    await _lspStart;
    return _lsp?.running == true ? _lsp : null;
  }

  Future<void> _startLsp() async {
    final lsp = LspClient(root);
    lsp.onApplyEdit = applyWorkspaceEdit;
    lsp.onExit = () {
      _lspStart = null;
      _opened.clear();
      notifyListeners();
    };
    _diagSub = lsp.diagnostics.stream.listen(_onDiagnostics);
    _statusSub = lsp.analyzing.stream.listen((v) {
      analyzing = v;
      notifyListeners();
    });
    try {
      await lsp.start();
      _lsp = lsp;
      lspError = null;
    } catch (e) {
      lspError = 'Dart analysis server failed to start: $e';
    }
    notifyListeners();
  }

  void _onDiagnostics(Map<String, dynamic> params) {
    final path = Uri.parse(params['uri'] as String).toFilePath();
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
      doc.diagnostics = diagnostics[path] ?? const [];
      doc.addListener(notifyListeners);
      doc._onSync = () => _sendChange(doc!);
      _diskPoll ??= Timer.periodic(const Duration(seconds: 2), (_) => _checkDisk());
      if (doc.languageId != null) unawaited(_openOnServer(doc));
    }
    active = doc;
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
  }

  void _sendChange(EditorDocument doc) {
    if (!_opened.contains(doc.path)) return;
    doc.version++;
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
    active = doc;
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
    if (active == doc) active = documents.isEmpty ? null : documents[i.clamp(0, documents.length - 1)];
    doc.removeListener(notifyListeners);
    notifyListeners();
    // After the tab's editor is gone from the tree.
    Timer(const Duration(milliseconds: 300), doc.dispose);
  }

  Future<void> save(EditorDocument doc) async {
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

  /// Hover text at a position, or null when there's nothing to say.
  Future<String?> hover(EditorDocument doc, int line, int column) async {
    final r = await _request(doc, 'textDocument/hover', _position(doc, line, column));
    if (r is! Map) return null;
    final contents = r['contents'];
    final text = contents is Map ? contents['value'] as String? : contents as String?;
    return (text == null || text.trim().isEmpty) ? null : plainHover(text);
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

  /// Applies a chosen completion: its text edit plus any auto-import.
  void applyCompletion(EditorDocument doc, CompletionEntry entry, {required int line, required int start, required int end}) {
    final raw = entry.raw;
    final textEdit = raw['textEdit'] as Map?;
    final newText = (textEdit?['newText'] ?? raw['insertText'] ?? raw['label']) as String;
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
    controller.selection = CodeLineSelection.collapsed(index: line + addedLines, offset: caretColumn);
    doc.flush();
  }

  @override
  void dispose() {
    _lsp?.onExit = null;
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
