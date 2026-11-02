import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../core/theme.dart';
import 'brackets.dart';
import 'debug_panel.dart' show breakpointColor;
import 'debugger.dart';
import 'editor_view.dart';
import 'engine/code_editor.dart';
import 'engine/snippet.dart';
import 'engine/syntax.dart';
import 'editor_workspace.dart';
import 'file_tree.dart' show fileIconOf;
import 'find_panel.dart';
import 'markdown_view.dart';
import 'source_control.dart';
import '../../core/mono_font.dart';
import '../../core/platform_keys.dart';

Color diagnosticColor(int severity) => switch (severity) {
  1 => const Color(0xFFEF4444),
  2 => const Color(0xFFF59E0B),
  _ => const Color(0xFF3B82F6),
};

/// Splits a highlighted line so each `(start, end, color)` range gets a wavy underline.
TextSpan underlineRanges(TextSpan span, List<(int, int, Color)> ranges) {
  var position = 0;

  TextSpan visit(TextSpan s) {
    final children = <InlineSpan>[];
    final text = s.text;
    if (text != null && text.isNotEmpty) {
      final start = position, end = position + text.length;
      final cuts = <int>{start, end};
      for (final (a, b, _) in ranges) {
        if (a > start && a < end) cuts.add(a);
        if (b > start && b < end) cuts.add(b);
      }
      final sorted = cuts.toList()..sort();
      for (var i = 0; i + 1 < sorted.length; i++) {
        final (a, b) = (sorted[i], sorted[i + 1]);
        final hit = ranges.where((r) => r.$1 <= a && b <= r.$2).firstOrNull;
        children.add(
          TextSpan(
            text: text.substring(a - start, b - start),
            style: hit == null
                ? null
                : TextStyle(
                    decoration: TextDecoration.underline,
                    decorationStyle: TextDecorationStyle.wavy,
                    decorationColor: hit.$3,
                  ),
          ),
        );
      }
      position = end;
    }
    for (final c in s.children ?? const <InlineSpan>[]) {
      children.add(c is TextSpan ? visit(c) : c);
    }
    return TextSpan(style: s.style, children: children);
  }

  return visit(span);
}

const _notClickable = {'keyword', 'string', 'number', 'comment'};

/// The analyzer's token under a column, when it names something Ctrl+click can go to.
SemanticToken? clickableTokenAt(List<SemanticToken>? tokens, int column) {
  for (final t in tokens ?? const <SemanticToken>[]) {
    if (t.start <= column && column < t.end && !_notClickable.contains(t.type)) return t;
  }
  return null;
}

const _lineComments = {
  '.dart': '//', '.kt': '//', '.kts': '//', '.java': '//', '.swift': '//', '.gradle': '//', '.js': '//',
  '.c': '//', '.h': '//', '.cc': '//', '.cpp': '//', '.yaml': '#', '.yml': '#', '.sh': '#', '.ps1': '#', '.toml': '#', '.properties': '#',
};

/// References without the one at a position, which is the word they were asked about.
List<EditTarget> usagesApartFrom(List<EditTarget> refs, String path, int line, int column, String lineText) => [
  for (final r in refs)
    if (!isDeclarationAt(r, path, line, column, lineText)) r,
];

/// Whether a definition lands on the very word at [column], meaning that word is the declaration.
bool isDeclarationAt(EditTarget target, String path, int line, int column, String lineText) {
  if (!p.equals(target.path, path) || target.line != line) return false;
  final at = column.clamp(0, lineText.length);
  final start = at - RegExp(r'[A-Za-z0-9_$]*$').firstMatch(lineText.substring(0, at))![0]!.length;
  final end = at + RegExp(r'^[A-Za-z0-9_$]*').firstMatch(lineText.substring(at))![0]!.length;
  return target.column >= start && target.column <= end;
}

/// The current theme's colors for an analyzer token kind; null leaves the text as it is.
Color? semanticColor(String type, Set<String> modifiers, Brightness brightness) {
  final theme = appTheme.value;
  // Only matters for a page drawn under another brightness than the theme's.
  final fallback = appThemes.firstWhere((t) => t.brightness == brightness);
  final syntax = theme.brightness == brightness ? theme.syntax : fallback.syntax;
  return switch (type) {
    'class' || 'enum' || 'typeAlias' || 'typeParameter' || 'namespace' || 'mixin' || 'extension' => syntax.type,
    'function' || 'method' || 'annotation' => syntax.function,
    'parameter' || 'variable' || 'property' => syntax.variable,
    'enumMember' => syntax.enumMember,
    'keyword' => modifiers.contains('control') ? syntax.control : syntax.keyword,
    'string' => syntax.string,
    'number' => syntax.number,
    'comment' => syntax.comment,
    _ => null,
  };
}

/// Splits a highlighted line so each `(start, end, color)` range takes that text color.
TextSpan colorRanges(TextSpan span, List<(int, int, Color)> ranges) {
  var position = 0;

  TextSpan visit(TextSpan s) {
    final children = <InlineSpan>[];
    final text = s.text;
    if (text != null && text.isNotEmpty) {
      final start = position, end = position + text.length;
      final cuts = <int>{start, end};
      for (final (a, b, _) in ranges) {
        if (a > start && a < end) cuts.add(a);
        if (b > start && b < end) cuts.add(b);
      }
      final sorted = cuts.toList()..sort();
      for (var i = 0; i + 1 < sorted.length; i++) {
        final (a, b) = (sorted[i], sorted[i + 1]);
        final hit = ranges.where((r) => r.$1 <= a && b <= r.$2).firstOrNull;
        children.add(TextSpan(text: text.substring(a - start, b - start), style: hit == null ? null : TextStyle(color: hit.$3)));
      }
      position = end;
    }
    for (final c in s.children ?? const <InlineSpan>[]) {
      children.add(c is TextSpan ? visit(c) : c);
    }
    return TextSpan(style: s.style, children: children);
  }

  return visit(span);
}

/// Draws a file's diagnostics as squiggles. Bound once per file, read fresh on every paint.
CodeLineSpanBuilder diagnosticsSpanBuilder(
  List<Diagnostic> Function() diagnostics, {
  Map<int, List<SemanticToken>> Function()? semantics,
}) =>
    ({required context, required index, required codeLine, required textSpan, required style}) {
      final tokens = semantics?.call()[index];
      if (tokens != null) {
        final brightness = Theme.of(context).brightness;
        textSpan = colorRanges(textSpan, [
          for (final t in tokens)
            if (semanticColor(t.type, t.modifiers, brightness) case final color?) (t.start, t.end, color),
        ]);
      }
      final here = diagnostics().where((d) => d.line <= index && index <= d.endLine);
      if (here.isEmpty) return textSpan;
      final length = codeLine.length;
      return underlineRanges(textSpan, [
        for (final d in here)
          () {
            final start = d.line == index ? d.column.clamp(0, length) : 0;
            var end = d.endLine == index ? d.endColumn.clamp(0, length) : length;
            // A zero-width range (e.g. a missing semicolon) still has to show.
            if (end <= start) end = (start + 1).clamp(0, length);
            return (end <= start && start > 0 ? start - 1 : start, end, diagnosticColor(d.severity));
          }(),
      ]);
    };

class CodePane extends StatefulWidget {
  const CodePane({super.key, required this.workspace, required this.doc, required this.debugger, required this.git, required this.onKey, required this.onTarget, required this.onReferences});

  final EditorWorkspace workspace;
  final Debugger debugger;
  final SourceControl git;
  final EditorDocument doc;

  /// Global shortcuts: consulted before the editor's own key bindings.
  final KeyEventResult Function(KeyEvent event) onKey;
  final ValueChanged<EditTarget> onTarget;
  final ValueChanged<List<EditTarget>> onReferences;

  @override
  State<CodePane> createState() => CodePaneState();
}

class CodePaneState extends State<CodePane> {
  late final _focus = FocusNode(debugLabel: 'code', onKeyEvent: _onKey);
  final _stackKey = GlobalKey();
  final _gutterKey = GlobalKey();
  final _popupScroll = ScrollController();
  CodeIndicatorValueNotifier? _indicator;
  CodeChunkController? _chunks;
  late var _find = CodeFindController(widget.doc.controller);

  // Completion popup.
  List<CompletionEntry> _items = const [];
  List<CompletionEntry> _shown = const [];
  SnippetSession? _snippet;
  var _selected = 0;
  bool _popup = false;
  int _popupLine = 0;
  int _wordStart = 0;
  bool _incomplete = false;
  Timer? _completionTimer;
  var _completionToken = 0;
  CodeLines? _lastLines;
  bool _applying = false;

  Map<int, GitMark> _marks = const {};
  Map<int, BlameLine> _blame = const {};
  var _wasDirty = false;

  // Docs beside the completion popup.
  String? _itemDocs;
  var _docsToken = 0;
  Timer? _docsTimer;

  // Parameter hints.
  SignatureInfo? _signature;
  Timer? _signatureTimer;
  var _signatureToken = 0;
  var _signatureLine = 0;
  var _signatureColumn = 0;

  // The bracket pair at the caret.
  Map<(int, int), (int, int)> _pairs = const {};
  CodeLines? _pairsOf;
  ((int, int), (int, int))? _bracket;

  // Shown while the server is slow to answer. Fast answers never get this far, so nothing flickers.
  String? _loading;
  Offset? _loadingAt;
  Timer? _loadingTimer;
  var _loadingToken = 0;
  var _loadingForHover = false;
  var _loadingIsNote = false;

  /// The loading token of a Ctrl+Space still waiting for its answer.
  int? _completionLoading;

  // Usages overlay.
  List<SearchHit>? _usages;
  List<EditTarget> _usageTargets = const [];
  var _usageIndex = 0;
  Offset? _usagesAt;
  var _usagesOf = '';
  final _usagesScroll = ScrollController();
  static const _usageRow = 24.0;

  // Ctrl+hover: the word that Ctrl+click would follow.
  (int, SemanticToken)? _link;
  Offset? _pointer;

  // Hover card.
  var _overHover = false;
  Timer? _hoverHide;
  (int, int, int)? _hoverWord;
  static const _hoverGrace = Duration(milliseconds: 350);
  String? _hover;
  Offset? _hoverAt;
  Timer? _hoverTimer;
  var _hoverToken = 0;

  EditorDocument get _doc => widget.doc;

  /// The line the selected stack frame stopped on, when that's in this file.
  int? get _currentLine {
    final frame = widget.debugger.currentFrame;
    return frame != null && frame.path != null && p.equals(frame.path!, _doc.path) ? frame.line : null;
  }

  CodeLineEditingController get _ctrl => _doc.controller;

  @override
  void initState() {
    super.initState();
    _lastLines = _ctrl.codeLines;
    _ctrl.addListener(_onEdit);
    widget.debugger.addListener(_onDebugger);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    EditorView.listenable.addListener(_onDebugger);
    widget.git.addListener(_loadMarks);
    EditorView.lineBlame.addListener(_loadMarks);
    _doc.addListener(_onDoc);
    _wasDirty = _doc.dirty;
    _loadMarks();
    _focus.addListener(() {
      if (!_focus.hasFocus) _closePopup();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _completionTimer?.cancel();
    _hoverTimer?.cancel();
    _hoverHide?.cancel();
    _loadingTimer?.cancel();
    _docsTimer?.cancel();
    _signatureTimer?.cancel();
    _ctrl.removeListener(_onEdit);
    widget.debugger.removeListener(_onDebugger);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    EditorView.listenable.removeListener(_onDebugger);
    widget.git.removeListener(_loadMarks);
    EditorView.lineBlame.removeListener(_loadMarks);
    _doc.removeListener(_onDoc);
    _find.dispose();
    _focus.dispose();
    _popupScroll.dispose();
    _usagesScroll.dispose();
    super.dispose();
  }

  // The marks compare the saved file with HEAD, so they only change on a save or a git operation.
  void _onDoc() {
    if (_wasDirty && !_doc.dirty) unawaited(widget.git.refresh());
    _wasDirty = _doc.dirty;
  }

  Future<void> _loadMarks() async {
    final doc = _doc;
    final marks = await widget.git.marksOf(doc.path);
    if (mounted && identical(doc, _doc) && !mapEquals(marks, _marks)) setState(() => _marks = marks);
    final blame = EditorView.lineBlame.value ? await widget.git.blameOf(doc.path) : const <int, BlameLine>{};
    if (mounted && identical(doc, _doc)) setState(() => _blame = blame);
  }

  /// Blame describes the saved file, so its line numbers mean nothing during unsaved edits.
  (String, Offset)? _blameAtCaret() {
    if (_doc.dirty || _blame.isEmpty) return null;
    final sel = _ctrl.selection;
    final blame = _blame[sel.extentIndex];
    if (blame == null || !sel.isCollapsed) return null;
    final end = _caretOffset(sel.extentIndex, _ctrl.codeLines[sel.extentIndex].length);
    final para = _paragraphAt(sel.extentIndex);
    if (end == null || para == null) return null;
    return (blame.describe(DateTime.now()), end - Offset(0, para.preferredLineHeight));
  }

  void _shiftBreakpoints(CodeLines before, CodeLines after, int cursor) {
    final delta = after.length - before.length;
    if (delta == 0) return;
    // A line whose text went blank was pushed down whole, so its breakpoint goes with it.
    final at = cursor - delta;
    final pushed = delta > 0 && at >= 0 && at < before.length && after[at].text.trim().isEmpty && before[at].text.trim().isNotEmpty;
    widget.debugger.shiftBreakpoints(_doc.path, cursor: cursor, delta: delta, atLineStart: pushed);
  }

  void _onDebugger() {
    if (mounted) setState(() {});
  }

  void toggleBreakpointAtCursor() {
    if (p.extension(_doc.path) == '.dart') widget.debugger.toggleBreakpoint(_doc.path, _ctrl.selection.extentIndex);
  }

  // One pane serves every tab, so changing tabs moves everything bound to the old document.
  @override
  void didUpdateWidget(CodePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.doc, widget.doc)) return;
    oldWidget.doc.controller.removeListener(_onEdit);
    oldWidget.doc.removeListener(_onDoc);
    _snippet = null;
    _ctrl.addListener(_onEdit);
    _doc.addListener(_onDoc);
    final previousFind = _find;
    _find = CodeFindController(_ctrl);
    WidgetsBinding.instance.addPostFrameCallback((_) => previousFind.dispose());
    _completionTimer?.cancel();
    _completionToken++;
    _docsTimer?.cancel();
    _docsToken++;
    _signatureTimer?.cancel();
    _signatureToken++;
    _hoverTimer?.cancel();
    _hoverHide?.cancel();
    _hoverHide = null;
    _hoverToken++;
    _lastLines = _ctrl.codeLines;
    _wasDirty = _doc.dirty;
    _pairsOf = null;
    _bracket = null;
    _usages = null;
    _loadingTimer?.cancel();
    _loadingToken++;
    _loading = null;
    _popup = false;
    _itemDocs = null;
    _signature = null;
    _hover = null;
    _overHover = false;
    _link = null;
    _pointer = null;
    _marks = const {};
    _blame = const {};
    unawaited(_loadMarks());
  }

  void reveal(int line, int column) {
    final last = _ctrl.lineCount - 1;
    final l = line.clamp(0, last);
    _ctrl.selection = CodeLineSelection.collapsed(index: l, offset: column.clamp(0, _ctrl.codeLines[l].length));
    _ctrl.makeCursorCenterIfInvisible();
    _focus.requestFocus();
  }

  // ------------------------------------------------------------- completion

  static final _wordBefore = RegExp(r'[A-Za-z0-9_$]*$');

  @visibleForTesting
  ((int, int), (int, int))? get matchedBrackets => _bracket;

  void _updateBrackets() {
    final sel = _ctrl.selection;
    final lines = _ctrl.codeLines;
    if (!identical(lines, _pairsOf)) {
      _pairsOf = lines;
      _pairs = bracketPairs([for (var i = 0; i < lines.length; i++) lines[i].text]);
    }
    final next = sel.isCollapsed ? pairAtCaret(_pairs, sel.extentIndex, sel.extentOffset) : null;
    if (next == _bracket) return;
    void apply() {
      if (mounted) setState(() => _bracket = next);
    }

    // The editor can notify while it's being built.
    SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks ? WidgetsBinding.instance.addPostFrameCallback((_) => apply()) : apply();
  }

  void _onEdit() {
    if (!mounted) return;
    _updateBrackets();
    if (_applying) return;
    final lines = _ctrl.codeLines;
    final changed = !identical(lines, _lastLines) && lines != _lastLines;
    final previous = _lastLines;
    _lastLines = lines;
    final sel = _ctrl.selection;
    if (changed && previous != null) _shiftBreakpoints(previous, lines, sel.extentIndex);
    if (!changed) {
      if (_popup && (!sel.isCollapsed || sel.extentIndex != _popupLine || sel.extentOffset < _wordStart)) _closePopup();
      if (_signature != null) _requestSignature();
      return;
    }
    _onTypedForSignature(sel);
    if (_doc.languageId != 'dart' || !sel.isCollapsed || !_focus.hasFocus) return _closePopup();
    // One keystroke changes one line slightly; formatting and multi-line pastes shouldn't open a popup.
    if (previous == null || previous.length != lines.length || sel.extentIndex >= lines.length) return _closePopup();
    final before = lines[sel.extentIndex].text.substring(0, sel.extentOffset.clamp(0, lines[sel.extentIndex].length));
    final word = _wordBefore.firstMatch(before)![0]!;
    final start = before.length - word.length;
    final afterDot = start > 0 && before[start - 1] == '.';
    if (word.isEmpty && !afterDot) return _closePopup();
    if (_popup && !_incomplete && _popupLine == sel.extentIndex && _wordStart == start) return _filter(word);
    _requestCompletion(sel.extentIndex, sel.extentOffset, start);
  }

  /// [manual] is Ctrl+Space, which always answers: a loading card while the analyzer gets ready, then
  /// the suggestions or a note that there are none.
  void _requestCompletion(int line, int column, int start, {bool manual = false}) {
    _completionTimer?.cancel();
    final token = ++_completionToken;
    if (_completionLoading != null) _endLoading();
    final loading = manual ? _beginLoading('Loading suggestions…', line, column) : null;
    _completionLoading = loading;
    bool stale() => !mounted || token != _completionToken || (loading != null && loading != _loadingToken);
    void finish() {
      if (loading != null && loading == _loadingToken) _endLoading();
      if (_completionLoading == loading) _completionLoading = null;
    }

    _completionTimer = Timer(const Duration(milliseconds: 60), () async {
      try {
        var items = await widget.workspace.completion(_doc, line, column);
        // The first answers can be empty while the file's analysis is still under way.
        for (var i = 0; manual && items.isEmpty && !stale() && i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          if (stale()) break;
          items = await widget.workspace.completion(_doc, line, column);
        }
        if (stale()) return finish();
        _items = items;
        _incomplete = false;
        _popupLine = line;
        _wordStart = start;
        final sel = _ctrl.selection;
        if (!sel.isCollapsed || sel.extentIndex != line) {
          finish();
          return _closePopup();
        }
        final text = _ctrl.codeLines[line].text;
        finish();
        _filter(text.substring(start.clamp(0, text.length), sel.extentOffset.clamp(start, text.length)));
        if (manual && _shown.isEmpty) _showCompletionNote('No suggestions', line, column);
      } on Exception {
        // The server restarting or a timeout only means no suggestions this time.
        finish();
      }
    });
  }

  void _showCompletionNote(String text, int line, int column) {
    final token = ++_loadingToken;
    _loadingTimer?.cancel();
    setState(() {
      _loading = text;
      _loadingIsNote = true;
      _loadingAt = _caretOffset(line, column);
    });
    _loadingTimer = Timer(const Duration(milliseconds: 1500), () {
      if (token == _loadingToken) _endLoading();
    });
  }

  void _filter(String word) {
    final shown = filterCompletions(_items, word);
    setState(() {
      _shown = shown;
      _popup = shown.isNotEmpty;
      _selected = 0;
    });
    if (_popupScroll.hasClients) _popupScroll.jumpTo(0);
    _loadItemDocs();
  }

  // Waits a beat, so arrowing through the list doesn't fire a request per row.
  void _loadItemDocs() {
    _docsTimer?.cancel();
    final token = ++_docsToken;
    if (!_popup || _shown.isEmpty) return;
    final entry = _shown[_selected];
    setState(() => _itemDocs = entry.documentation);
    if (entry.documentation != null) return;
    _docsTimer = Timer(const Duration(milliseconds: 120), () async {
      try {
        final docs = await widget.workspace.documentationOf(_doc, entry);
        if (mounted && token == _docsToken) setState(() => _itemDocs = docs);
      } on Exception {
        // No docs this time; the suggestion itself still works.
      }
    });
  }

  void _onTypedForSignature(CodeLineSelection sel) {
    if (_doc.languageId != 'dart' || !sel.isCollapsed || sel.extentIndex >= _ctrl.codeLines.length) return _closeSignature();
    final text = _ctrl.codeLines[sel.extentIndex].text;
    final before = text.substring(0, sel.extentOffset.clamp(0, text.length)).trimRight();
    if (before.endsWith('(') || before.endsWith(',') || _signature != null) _requestSignature();
  }

  void _requestSignature() {
    _signatureTimer?.cancel();
    final token = ++_signatureToken;
    _signatureTimer = Timer(const Duration(milliseconds: 80), () async {
      final sel = _ctrl.selection;
      if (!mounted || !sel.isCollapsed) return _closeSignature();
      try {
        final info = await widget.workspace.signatureHelp(_doc, sel.extentIndex, sel.extentOffset);
        if (!mounted || token != _signatureToken) return;
        setState(() {
          _signature = info;
          _signatureLine = sel.extentIndex;
          _signatureColumn = sel.extentOffset;
        });
      } on Exception {
        // Code mid-edit may not parse; the hint comes back on the next keystroke.
      }
    });
  }

  void _closeSignature() {
    _signatureTimer?.cancel();
    _signatureToken++;
    if (_signature != null && mounted) setState(() => _signature = null);
  }

  void _closePopup() {
    _completionTimer?.cancel();
    _completionToken++;
    if (_completionLoading != null) {
      _completionLoading = null;
      _endLoading();
    }
    _docsTimer?.cancel();
    _docsToken++;
    if (_popup && mounted) {
      setState(() {
        _popup = false;
        _itemDocs = null;
      });
    }
  }

  Future<void> _accept(CompletionEntry entry) async {
    final line = _popupLine, start = _wordStart;
    _closePopup();
    final resolved = await widget.workspace.resolveCompletion(_doc, entry);
    if (!mounted) return;
    _applying = true;
    _snippet = widget.workspace.applyCompletion(_doc, resolved, line: line, start: start, end: _ctrl.selection.extentOffset);
    _lastLines = _ctrl.codeLines;
    _applying = false;
    _ctrl.makeCursorVisible();
    _focus.requestFocus();
  }

  void _moveSelection(int delta) {
    setState(() => _selected = (_selected + delta) % _shown.length);
    _loadItemDocs();
    if (_popupScroll.hasClients) {
      final target = _selected * _rowHeight;
      final view = _popupScroll.position.viewportDimension;
      if (target < _popupScroll.offset) {
        _popupScroll.jumpTo(target);
      } else if (target + _rowHeight > _popupScroll.offset + view) {
        _popupScroll.jumpTo(target + _rowHeight - view);
      }
    }
  }

  // ------------------------------------------------------------- keyboard

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final hw = HardwareKeyboard.instance;
    if (_loading != null && key == LogicalKeyboardKey.escape) return _handled(_endLoading);
    if (_usages != null) {
      if (key == LogicalKeyboardKey.escape) return _handled(_closeUsages);
      if (key == LogicalKeyboardKey.arrowDown) return _handled(() => _moveUsage(1));
      if (key == LogicalKeyboardKey.arrowUp) return _handled(() => _moveUsage(-1));
      if (key == LogicalKeyboardKey.enter) return _handled(() => _openUsage(_usageIndex));
    }
    if (_popup) {
      if (key == LogicalKeyboardKey.arrowDown) return _handled(() => _moveSelection(1));
      if (key == LogicalKeyboardKey.arrowUp) return _handled(() => _moveSelection(-1));
      if (key == LogicalKeyboardKey.escape) return _handled(_closePopup);
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
        return _handled(() => _accept(_shown[_selected]));
      }
    }
    final snippet = _snippet;
    if (snippet != null) {
      if (key == LogicalKeyboardKey.escape) {
        _snippet = null;
      } else if (key == LogicalKeyboardKey.tab) {
        if (snippet.move(hw.isShiftPressed ? -1 : 1)) {
          if (!snippet.active) _snippet = null;
          return KeyEventResult.handled;
        }
        _snippet = null;
      }
    }
    if (_hover != null && key == LogicalKeyboardKey.escape) return _handled(_clearHover);
    if (_signature != null && key == LogicalKeyboardKey.escape) return _handled(_closeSignature);
    if (hw.isControlPressed && hw.isShiftPressed && key == LogicalKeyboardKey.space) return _handled(_requestSignature);
    final vsCode = _vsCodeKey(key, hw, readOnly: isLibrarySource(_doc.path));
    if (vsCode != null) return _handled(vsCode);
    final sel = _ctrl.selection;
    final (line, col) = (sel.extentIndex, sel.extentOffset);
    if (hw.isControlPressed && key == LogicalKeyboardKey.space) {
      return _handled(() {
        final text = _ctrl.codeLines[line].text;
        final before = text.substring(0, col.clamp(0, text.length));
        _requestCompletion(line, col, before.length - _wordBefore.firstMatch(before)![0]!.length, manual: true);
      });
    }
    if (key == LogicalKeyboardKey.f12) {
      return _handled(() => hw.isShiftPressed ? _findReferences(line, col) : _goToDefinition(line, col));
    }
    if (key == LogicalKeyboardKey.f2) return _handled(() => _rename(line, col));
    if (key == LogicalKeyboardKey.f1) return _handled(() => _showHoverAtCaret(line, col));
    if (hw.isPrimaryPressed && key == LogicalKeyboardKey.period) return _handled(() => _codeActions(line, col));
    return widget.onKey(event);
  }

  VoidCallback? _vsCodeKey(LogicalKeyboardKey key, HardwareKeyboard hw, {required bool readOnly}) {
    final ctrl = hw.isPrimaryPressed, shift = hw.isShiftPressed, alt = hw.isAltPressed;
    if (ctrl && !shift && key == LogicalKeyboardKey.keyD) return _ctrl.selectNextOccurrence;
    if (!readOnly) {
      if (ctrl && key == LogicalKeyboardKey.enter) return shift ? _insertLineAbove : _insertLineBelow;
      if (shift && alt && key == LogicalKeyboardKey.arrowDown) return () => _copyLines(down: true);
      if (shift && alt && key == LogicalKeyboardKey.arrowUp) return () => _copyLines(down: false);
      if (ctrl && !shift && key == LogicalKeyboardKey.bracketRight) return _ctrl.applyIndent;
      if (ctrl && !shift && key == LogicalKeyboardKey.bracketLeft) return _ctrl.applyOutdent;
    }
    if (ctrl && shift && (key == LogicalKeyboardKey.bracketLeft || key == LogicalKeyboardKey.braceLeft)) return _fold;
    if (ctrl && shift && (key == LogicalKeyboardKey.bracketRight || key == LogicalKeyboardKey.braceRight)) return _unfold;
    final byWord = Platform.isMacOS ? alt : ctrl;
    if (byWord && key == LogicalKeyboardKey.arrowRight) {
      return shift ? _ctrl.extendSelectionToWordBoundaryForward : _ctrl.moveCursorToWordBoundaryForward;
    }
    if (byWord && key == LogicalKeyboardKey.arrowLeft) {
      return shift ? _ctrl.extendSelectionToWordBoundaryBackward : _ctrl.moveCursorToWordBoundaryBackward;
    }
    if (key == LogicalKeyboardKey.f3) return shift ? _find.previousMatch : _find.nextMatch;
    return null;
  }

  static String _indentOf(String line) => RegExp(r'^\s*').firstMatch(line)![0]!;

  void _insertLineBelow() {
    _ctrl.moveCursorToLineEnd();
    _ctrl.applyNewLine();
  }

  void _insertLineAbove() {
    final index = _ctrl.selection.extentIndex;
    final indent = _indentOf(_ctrl.codeLines[index].text);
    _ctrl.selection = CodeLineSelection.collapsed(index: index, offset: 0);
    _ctrl.replaceSelection('$indent\n');
    _ctrl.selection = CodeLineSelection.collapsed(index: index, offset: indent.length);
  }

  void _copyLines({required bool down}) {
    final sel = _ctrl.selection;
    final start = sel.startIndex, end = sel.endIndex;
    final block = [for (var i = start; i <= end; i++) _ctrl.codeLines[i].text].join('\n');
    final count = end - start + 1;
    _ctrl.selection = CodeLineSelection.collapsed(index: end, offset: _ctrl.codeLines[end].length);
    _ctrl.replaceSelection('\n$block');
    // Going up, the cursor stays on the upper copy; going down, it follows onto the lower one.
    final shift = down ? count : 0;
    _ctrl.selection = CodeLineSelection(
      baseIndex: sel.baseIndex + shift,
      baseOffset: sel.baseOffset,
      extentIndex: sel.extentIndex + shift,
      extentOffset: sel.extentOffset,
    );
  }

  void _fold() {
    final line = _ctrl.selection.extentIndex;
    final around = (_chunks?.value ?? const <CodeChunk>[]).where((c) => c.index <= line && line <= c.end && c.canCollapse);
    if (around.isEmpty) return;
    final inner = around.reduce((a, b) => a.index > b.index ? a : b);
    _ctrl.collapseChunk(inner.index, inner.end);
  }

  void _unfold() {
    final line = _ctrl.selection.extentIndex;
    if (_ctrl.codeLines[line].chunkParent) _ctrl.expandChunk(line);
  }

  KeyEventResult _handled(void Function() action) {
    action();
    return KeyEventResult.handled;
  }

  void _toast(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), width: 460, behavior: SnackBarBehavior.floating));

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Exception catch (e) {
      if (mounted) _toast('$e');
    }
  }

  Future<void> _goToDefinition(int line, int col) => _guard(() async {
    final token = _beginLoading('Loading…', line, col);
    final EditTarget? target;
    try {
      target = await widget.workspace.definition(_doc, line, col);
      if (!mounted || token != _loadingToken) return;
    } finally {
      if (token == _loadingToken) _endLoading();
    }
    if (target == null) return _toast('No definition found here');
    widget.onTarget(target);
  });

  Future<void> _findReferences(int line, int col) => _guard(() async {
    final text = _ctrl.codeLines[line].text;
    final at = col.clamp(0, text.length);
    final word = _wordBefore.firstMatch(text.substring(0, at))![0]! + RegExp(r'^[A-Za-z0-9_$]*').firstMatch(text.substring(at))![0]!;
    final token = _beginLoading(word.isEmpty ? 'Finding usages…' : 'Finding usages of $word…', line, col);
    final List<EditTarget> usages;
    final List<SearchHit> hits;
    try {
      final refs = await widget.workspace.references(_doc, line, col);
      if (!mounted || token != _loadingToken) return;
      usages = usagesApartFrom(refs, _doc.path, line, col, text);
      hits = await widget.workspace.referenceHits(usages);
      if (!mounted || token != _loadingToken) return;
    } finally {
      if (token == _loadingToken) _endLoading();
    }
    if (usages.isEmpty) return _toast(word.isEmpty ? 'No usages found' : 'No usages of $word found');
    _clearHover();
    setState(() {
      _usages = hits;
      _usageTargets = usages;
      _usageIndex = 0;
      _usagesOf = word;
      _usagesAt = _caretOffset(line, col);
    });
    if (_usagesScroll.hasClients) _usagesScroll.jumpTo(0);
  });

  int _beginLoading(String label, int line, int column, {bool hover = false}) {
    final token = ++_loadingToken;
    _loadingForHover = hover;
    _loadingTimer?.cancel();
    _loadingTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || token != _loadingToken) return;
      setState(() {
        _loading = label;
        _loadingIsNote = false;
        _loadingAt = _caretOffset(line, column);
      });
    });
    return token;
  }

  /// Also what cancels: an answer for an older token is dropped.
  void _endLoading() {
    _loadingToken++;
    _loadingTimer?.cancel();
    if (_loading != null && mounted) setState(() => _loading = null);
  }

  Widget _buildLoading(ColorScheme scheme) => _Floating(
    at: _loadingAt ?? Offset.zero,
    lineHeight: 20,
    width: 320,
    height: 34,
    shrink: true,
    child: TapRegion(
      onTapOutside: (_) => _endLoading(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_loadingIsNote) ...[
              SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary)),
              const SizedBox(width: 8),
            ],
            Flexible(child: Text(_loading!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
          ],
        ),
      ),
    ),
  );

  void _closeUsages() {
    if (_usages != null && mounted) setState(() => _usages = null);
  }

  void _openUsage(int index) {
    final target = _usageTargets[index];
    _closeUsages();
    widget.onTarget(target);
  }

  void _moveUsage(int delta) {
    final count = _usageTargets.length;
    setState(() => _usageIndex = (_usageIndex + delta) % count);
    if (!_usagesScroll.hasClients) return;
    // Rows above include the header of each file up to this one.
    final top = _usageRowsBefore(_usageIndex) * _usageRow;
    final view = _usagesScroll.position.viewportDimension;
    if (top < _usagesScroll.offset) {
      _usagesScroll.jumpTo(top);
    } else if (top + _usageRow > _usagesScroll.offset + view) {
      _usagesScroll.jumpTo(top + _usageRow - view);
    }
  }

  int _usageRowsBefore(int index) {
    var rows = index + 1;
    for (var i = 1; i <= index; i++) {
      if (_usageTargets[i].path != _usageTargets[i - 1].path) rows++;
    }
    return rows;
  }

  Widget _buildUsages(ColorScheme scheme) {
    final hits = _usages!;
    final at = _usagesAt ?? Offset.zero;
    final root = widget.workspace.root;
    final rows = <Widget>[];
    for (final (i, h) in hits.indexed) {
      if (i == 0 || hits[i - 1].path != h.path) {
        final count = hits.where((x) => x.path == h.path).length;
        final (icon, color) = fileIconOf(h.path);
        rows.add(
          Container(
            height: _usageRow,
            color: scheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(icon, size: 14, color: color ?? scheme.outline),
                const SizedBox(width: 6),
                Text(p.basename(h.path), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.isWithin(root, h.path) ? p.relative(p.dirname(h.path), from: root) : p.dirname(h.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: scheme.outline),
                  ),
                ),
                Text('$count', style: TextStyle(fontSize: 11.5, color: scheme.outline)),
              ],
            ),
          ),
        );
      }
      rows.add(
        InkWell(
          onTap: () => _openUsage(i),
          child: Container(
            height: _usageRow,
            color: i == _usageIndex ? scheme.primary.withValues(alpha: .16) : null,
            padding: const EdgeInsets.only(left: 12, right: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 42,
                  child: Text('${h.line + 1}', textAlign: TextAlign.right, style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12, color: scheme.outline)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(h.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final title = '${hits.length} ${hits.length == 1 ? 'usage' : 'usages'} of $_usagesOf';
    return _Floating(
      at: at,
      lineHeight: 20,
      width: 640,
      height: (rows.length * _usageRow + 30).clamp(0, 360).toDouble(),
      child: TapRegion(
        onTapOutside: (_) => _closeUsages(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 28,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600))),
                  TextButton(
                    style: TextButton.styleFrom(textStyle: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      final targets = _usageTargets;
                      _closeUsages();
                      widget.onReferences(targets);
                    },
                    child: const Text('Open in panel'),
                  ),
                  IconButton(
                    tooltip: 'Close (Esc)',
                    iconSize: 14,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 24, height: 24),
                    onPressed: _closeUsages,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(controller: _usagesScroll, padding: EdgeInsets.zero, itemExtent: _usageRow, children: rows),
            ),
          ],
        ),
      ),
    );
  }

  /// As in VS Code: Ctrl+click on a usage goes to its definition, on the declaration itself it lists the usages.
  Future<void> _ctrlClick(int line, int col) => _guard(() async {
    final token = _beginLoading('Loading…', line, col);
    final EditTarget? target;
    try {
      target = await widget.workspace.definition(_doc, line, col);
      if (!mounted || token != _loadingToken) return;
    } finally {
      if (token == _loadingToken) _endLoading();
    }
    if (target != null && !isDeclarationAt(target, _doc.path, line, col, _ctrl.codeLines[line].text)) return widget.onTarget(target);
    await _findReferences(line, col);
  });

  Future<void> _contextMenu(Offset global, int line, int col) async {
    _ctrl.selection = CodeLineSelection.collapsed(index: line, offset: col);
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(global);
    final picked = await showMenu<void Function()>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
      items: [
        PopupMenuItem(height: 30, value: () => _goToDefinition(line, col), child: const _MenuRow('Go to Definition', 'F12')),
        PopupMenuItem(height: 30, value: () => _findReferences(line, col), child: const _MenuRow('Find All References', 'Shift+F12')),
        PopupMenuItem(height: 30, value: () => _rename(line, col), child: const _MenuRow('Rename Symbol', 'F2')),
        const PopupMenuDivider(),
        PopupMenuItem(height: 30, value: () => _codeActions(line, col), child: const _MenuRow('Quick Fix…', 'Ctrl+.')),
        PopupMenuItem(height: 30, value: () => _showHoverAtCaret(line, col), child: const _MenuRow('Show Docs', 'F1')),
        const PopupMenuDivider(),
        PopupMenuItem(height: 30, value: EditorView.toggleLineBlame, child: _MenuRow(EditorView.lineBlame.value ? 'Hide Line Blame' : 'Show Line Blame', '')),
      ],
    );
    picked?.call();
  }

  Future<void> _rename(int line, int col) => _guard(() async {
    final text = _ctrl.codeLines[line].text;
    final left = _wordBefore.firstMatch(text.substring(0, col.clamp(0, text.length)))![0]!;
    final right = RegExp(r'^[A-Za-z0-9_$]*').firstMatch(text.substring(col.clamp(0, text.length)))![0]!;
    final ctrl = TextEditingController(text: '$left$right')..selection = TextSelection(baseOffset: 0, extentOffset: left.length + right.length);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename symbol'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Rename')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty) return;
    await widget.workspace.rename(_doc, line, col, name.trim());
    _focus.requestFocus();
  });

  Future<void> _codeActions(int line, int col) => _guard(() async {
    final actions = await widget.workspace.codeActions(_doc, line, col);
    if (!mounted) return;
    if (actions.isEmpty) return _toast('No quick fixes here');
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Quick fix'),
        children: [
          SizedBox(
            width: 520,
            height: (actions.length * 44.0).clamp(44, 420),
            child: ListView(
              children: [
                for (final a in actions)
                  ListTile(
                    dense: true,
                    leading: Icon(a['kind'] == 'quickfix' ? Icons.lightbulb_outline : Icons.auto_fix_high, size: 18),
                    title: Text(a['title'] as String),
                    onTap: () => Navigator.pop(ctx, a),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (chosen != null) await widget.workspace.runCodeAction(chosen);
    _focus.requestFocus();
  });

  // ------------------------------------------------------------- geometry

  /// The code field's top-left, in the stack's coordinates. The find panel moves it down.
  Offset? _fieldOrigin() {
    final gutter = _gutterKey.currentContext?.findRenderObject() as RenderBox?;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (gutter == null || stack == null || !gutter.attached) return null;
    return stack.globalToLocal(gutter.localToGlobal(Offset(gutter.size.width, 0)));
  }

  CodeLineRenderParagraph? _paragraphAt(int line) =>
      _indicator?.value?.paragraphs.where((x) => x.index == line).firstOrNull;

  @visibleForTesting
  bool get showsLink => _link != null;

  /// The middle of a character on screen.
  @visibleForTesting
  Offset? globalCenterOf(int line, int column) {
    final at = _caretOffset(line, column);
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final height = _paragraphAt(line)?.preferredLineHeight;
    if (at == null || stack == null || height == null) return null;
    return stack.localToGlobal(at + Offset(3, -height / 2));
  }

  /// Where the bottom-left of a character sits, in the stack's coordinates.
  Offset? _caretOffset(int line, int column) {
    final para = _paragraphAt(line);
    final origin = _fieldOrigin();
    if (para == null || origin == null) return null;
    final at = para.paragraph.getOffset(TextPosition(offset: column)) ?? Offset.zero;
    return origin + para.offset + at + Offset(0, para.paragraph.preferredLineHeight);
  }

  (int, int)? _positionAt(Offset local) {
    final origin = _fieldOrigin();
    if (origin == null) return null;
    final inField = local - origin;
    if (inField.dx < 0) return null;
    for (final para in _indicator?.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
      final top = para.offset.dy;
      if (inField.dy >= top && inField.dy < top + para.paragraph.height) {
        final pos = para.paragraph.getPosition(inField - para.offset);
        return (para.index, pos.offset);
      }
    }
    return null;
  }

  // ------------------------------------------------------------- hover

  void _clearHover() {
    if (_loadingForHover) _endLoading();
    _loadingForHover = false;
    _hoverTimer?.cancel();
    _hoverHide?.cancel();
    _hoverHide = null;
    _hoverToken++;
    _overHover = false;
    if (_hover != null) setState(() => _hover = null);
  }

  // Pressing or releasing Ctrl with the mouse at rest has to update the link too.
  bool _onHardwareKey(KeyEvent e) {
    if (mounted && isPrimaryModifierKey(e.logicalKey)) _updateLink();
    return false;
  }

  void _updateLink() {
    (int, SemanticToken)? link;
    final at = _pointer;
    if (at != null && HardwareKeyboard.instance.isPrimaryPressed && _doc.languageId == 'dart') {
      final pos = _positionAt(at);
      if (pos != null) {
        final token = clickableTokenAt(_doc.semantics[pos.$1], pos.$2);
        if (token != null) link = (pos.$1, token);
      }
    }
    if (link?.$1 != _link?.$1 || !identical(link?.$2, _link?.$2)) setState(() => _link = link);
  }

  Widget _buildLink(ColorScheme scheme) {
    final (line, token) = _link!;
    final start = _caretOffset(line, token.start), end = _caretOffset(line, token.end);
    final height = _paragraphAt(line)?.preferredLineHeight;
    if (start == null || end == null || height == null) return const SizedBox.shrink();
    return Positioned(
      left: start.dx,
      top: start.dy - height,
      width: end.dx - start.dx,
      height: height,
      // Translucent: this only changes the cursor, the click still reaches the editor below.
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        hitTestBehavior: HitTestBehavior.translucent,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: scheme.primary))),
          ),
        ),
      ),
    );
  }

  void _onHover(PointerHoverEvent e) {
    _pointer = e.localPosition;
    _updateLink();
    // Moving onto the card is how you read or select its text, so it has to stay.
    if (_overHover) return;
    if (_hover != null) {
      final pos = _positionAt(e.localPosition), word = _hoverWord;
      if (pos != null && word != null && pos.$1 == word.$1 && pos.$2 >= word.$2 && pos.$2 <= word.$3) {
        _hoverHide?.cancel();
        _hoverHide = null;
        return;
      }
      _hoverHide ??= Timer(_hoverGrace, _clearHover);
      return;
    }
    _clearHover();
    if (HardwareKeyboard.instance.isPrimaryPressed || _usages != null) return;
    if (_doc.languageId != 'dart' || _popup) return;
    final local = e.localPosition;
    _hoverTimer = Timer(const Duration(milliseconds: 500), () => _showHover(local));
  }

  /// A diagnostic under the pointer comes first: that's usually what the user is looking at.
  Future<void> _showHover(Offset local) async {
    final pos = _positionAt(local);
    if (pos == null) return;
    final (line, col) = pos;
    final text = _ctrl.codeLines[line].text;
    if (col >= text.length) return;
    await _loadHover(line, col, _caretOffset(line, col) ?? local);
  }

  Future<void> _showHoverAtCaret(int line, int col) async {
    final at = _caretOffset(line, col);
    if (at != null) await _loadHover(line, col, at);
  }

  Future<void> _loadHover(int line, int col, Offset at) async {
    final token = ++_hoverToken;
    final problems = _doc.diagnostics.where(
      (d) =>
          (d.line < line || (d.line == line && d.column <= col)) &&
          (d.endLine > line || (d.endLine == line && d.endColumn >= col)),
    );
    String? info;
    final loading = _beginLoading('Loading…', line, col, hover: true);
    try {
      info = await widget.workspace.hover(_doc, line, col);
    } on Exception {
      info = null;
    }
    if (loading == _loadingToken) _endLoading();
    if (!mounted || token != _hoverToken) return;
    final parts = [...problems.map((d) => d.message), ?info];
    if (parts.isEmpty) return;
    setState(() {
      _hover = parts.join('\n\n---\n');
      _hoverAt = at;
      final text = _ctrl.codeLines[line].text;
      final from = col.clamp(0, text.length);
      _hoverWord = (
        line,
        from - _wordBefore.firstMatch(text.substring(0, from))![0]!.length,
        from + RegExp(r'^[A-Za-z0-9_$]*').firstMatch(text.substring(from))![0]!.length,
      );
    });
  }

  // ------------------------------------------------------------- build

  static const _rowHeight = 26.0;
  static const _popupRegion = 'completion';

  Widget _buildItemDocs() {
    const popupWidth = 460.0, width = 400.0, gap = 6.0;
    final at = _caretOffset(_popupLine, _wordStart);
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (at == null || stack == null || !stack.hasSize) return const SizedBox.shrink();
    final popupLeft = at.dx.clamp(0, (stack.size.width - popupWidth).clamp(0, double.infinity)).toDouble();
    final double left;
    if (popupLeft + popupWidth + gap + width <= stack.size.width) {
      left = popupLeft + popupWidth + gap;
    } else if (popupLeft >= width + gap) {
      left = popupLeft - width - gap;
    } else {
      return const SizedBox.shrink();
    }
    return _Floating(
      at: Offset(left, at.dy),
      lineHeight: _paragraphAt(_popupLine)?.paragraph.preferredLineHeight ?? 18,
      width: width,
      height: 262,
      shrink: true,
      child: TapRegion(
        groupId: _popupRegion,
        child: SingleChildScrollView(padding: const EdgeInsets.all(10), child: MarkdownView(_itemDocs!)),
      ),
    );
  }

  Widget _buildSignature(ColorScheme scheme) {
    final s = _signature!;
    final at = _caretOffset(_signatureLine, _signatureColumn);
    if (at == null) return const SizedBox.shrink();
    final line = _paragraphAt(_signatureLine)?.paragraph.preferredLineHeight ?? 18;
    const mono = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 13);
    return _Floating(
      // Above the line, so it doesn't cover the arguments below it.
      at: at,
      lineHeight: line,
      width: 640,
      height: 150,
      shrink: true,
      above: true,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: s.label.substring(0, s.activeStart)),
                  TextSpan(
                    text: s.label.substring(s.activeStart, s.activeEnd),
                    style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: s.label.substring(s.activeEnd)),
                ],
              ),
              style: mono,
            ),
            if (s.documentation != null) ...[const Divider(height: 14), MarkdownView(s.documentation!)],
          ],
        ),
      ),
    );
  }

  Widget _buildPopup(ColorScheme scheme) {
    final at = _caretOffset(_popupLine, _wordStart);
    if (at == null) return const SizedBox.shrink();
    return _Floating(
      at: at,
      lineHeight: _paragraphAt(_popupLine)?.paragraph.preferredLineHeight ?? 18,
      width: 460,
      height: (_shown.length * _rowHeight + 2).clamp(0, 262).toDouble(),
      child: TapRegion(
        groupId: _popupRegion,
        onTapOutside: (_) => _closePopup(),
        child: ListView.builder(
        controller: _popupScroll,
        padding: EdgeInsets.zero,
        itemExtent: _rowHeight,
        itemCount: _shown.length,
        itemBuilder: (_, i) {
          final c = _shown[i];
          return InkWell(
            onTap: () => _accept(c),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: i == _selected ? scheme.primary.withValues(alpha: .16) : null,
              child: Row(
                children: [
                  Icon(_kindIcon(c.kind), size: 14, color: scheme.primary),
                  const SizedBox(width: 8),
                  Flexible(
                    flex: 3,
                    child: Text.rich(
                      TextSpan(
                        text: c.label,
                        children: [
                          // Some labels already carry their parameters.
                          if (c.signature.isNotEmpty && !c.label.contains('('))
                            TextSpan(text: c.signature, style: TextStyle(color: scheme.outline)),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 13),
                    ),
                  ),
                  if (c.detail != null) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      flex: 2,
                      child: Text(
                        c.detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (e) {
        if (e.buttons != kSecondaryMouseButton || _doc.languageId != 'dart') return;
        final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
        final pos = box == null ? null : _positionAt(box.globalToLocal(e.position));
        if (pos != null) unawaited(_contextMenu(e.position, pos.$1, pos.$2));
      },
      onPointerUp: (e) {
        if (!HardwareKeyboard.instance.isPrimaryPressed) return;
        // From the pointer, not the caret: the editor may not have moved the caret yet.
        final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
        final pos = box == null ? null : _positionAt(box.globalToLocal(e.position));
        if (pos != null) unawaited(_ctrlClick(pos.$1, pos.$2));
      },
      child: MouseRegion(
        onHover: _onHover,
        onExit: (_) {
          _pointer = null;
          _updateLink();
          _clearHover();
        },
        child: Stack(
          key: _stackKey,
          children: [
            CodeEditor(
              key: ObjectKey(_doc),
              controller: _ctrl,
              focusNode: _focus,
              scrollController: _doc.scroll,
              findController: _find,
              readOnly: isLibrarySource(_doc.path),
              language: languageForExtension(p.extension(_doc.path)),
              lineComment: _lineComments[p.extension(_doc.path).toLowerCase()],
              wordWrap: EditorView.wordWrap.value,
              padding: const EdgeInsets.only(left: 6, top: 4, bottom: 120, right: 16),
              style: CodeEditorStyle(
                fontFamily: 'Cascadia Mono',
                fontFamilyFallback: const ['Consolas', ...monoFallback],
                fontSize: EditorView.fontSize.value,
                fontHeight: 1.4,
                backgroundColor: scheme.surface,
                textColor: scheme.onSurface,
                cursorColor: scheme.primary,
                selectionColor: scheme.primary.withValues(alpha: .25),
                cursorLineColor: scheme.onSurface.withValues(alpha: .04),
                syntax: appTheme.value.syntax,
              ),
              indicatorBuilder: (_, editing, chunks, notifier) {
                _indicator = notifier;
                _chunks = chunks;
                return Row(
                  key: _gutterKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BreakpointGutter(
                      notifier: notifier,
                      lines: widget.debugger.breakpoints[_doc.path] ?? const {},
                      current: _currentLine,
                      marks: _marks,
                      onToggle: p.extension(_doc.path) == '.dart' ? (l) => widget.debugger.toggleBreakpoint(_doc.path, l) : null,
                    ),
                    DefaultCodeLineNumber(
                      controller: editing,
                      notifier: notifier,
                      textStyle: TextStyle(color: scheme.outline, fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: EditorView.fontSize.value - 1),
                      focusedTextStyle: TextStyle(color: scheme.onSurface, fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: EditorView.fontSize.value - 1),
                    ),
                    DefaultCodeChunkIndicator(width: 18, controller: chunks, editing: editing, notifier: notifier, color: scheme.outline),
                  ],
                );
              },
              findBuilder: (_, controller, readOnly) => CodeFindPanel(controller: controller, readOnly: readOnly),
            ),
            if (_currentLine != null && _indicator != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _LinePainter(_indicator!, (size) {
                      // These run at paint, which can come after an edit cleared what the last build saw.
                      final line = _currentLine;
                      final para = line == null ? null : _paragraphAt(line);
                      final origin = _fieldOrigin();
                      if (para == null || origin == null) return null;
                      return Rect.fromLTWH(origin.dx, origin.dy + para.offset.dy, size.width - origin.dx, para.height);
                    }),
                  ),
                ),
              ),
            if (EditorView.lineBlame.value && _indicator != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BlamePainter(_indicator!, scheme.outline, EditorView.fontSize.value - 1, _blameAtCaret, () => _fieldOrigin()?.dx ?? 0),
                  ),
                ),
              ),
            if (_bracket != null && _indicator != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BracketPainter(_indicator!, scheme.primary, () {
                      final pair = _bracket;
                      if (pair == null) return const [];
                      final (a, b) = pair;
                      return [
                        for (final (line, column) in [a, b])
                          if (_caretOffset(line, column) case final start?)
                            if (_caretOffset(line, column + 1) case final end?)
                              Rect.fromLTRB(start.dx, start.dy - (_paragraphAt(line)?.preferredLineHeight ?? 0), end.dx, start.dy),
                      ];
                    }),
                  ),
                ),
              ),
            if (_link != null) _buildLink(scheme),
            if (_signature != null && !_popup) _buildSignature(scheme),
            if (_usages != null) _buildUsages(scheme),
            if (_loading != null) _buildLoading(scheme),
            if (_popup) _buildPopup(scheme),
            if (_popup && _itemDocs != null) _buildItemDocs(),
            if (_hover != null && _hoverAt != null)
              _Floating(
                at: _hoverAt!,
                lineHeight: 20,
                width: 600,
                height: 340,
                shrink: true,
                child: MouseRegion(
                  onEnter: (_) {
                    _overHover = true;
                    _hoverHide?.cancel();
                    _hoverHide = null;
                  },
                  onExit: (_) {
                    _overHover = false;
                    _hoverHide ??= Timer(_hoverGrace, _clearHover);
                  },
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: MarkdownView(_hover!),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData _kindIcon(int kind) => switch (kind) {
  2 || 3 || 4 => Icons.functions,
  5 || 10 => Icons.label_outline,
  6 => Icons.data_object,
  7 || 8 => Icons.category_outlined,
  9 => Icons.inventory_2_outlined,
  13 || 20 => Icons.format_list_bulleted,
  14 => Icons.key_outlined,
  15 => Icons.code,
  _ => Icons.short_text,
};

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.label, this.keys);

  final String label, keys;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
      const SizedBox(width: 28),
      Text(platformKeys(keys), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
    ],
  );
}

class _BreakpointGutter extends StatefulWidget {
  const _BreakpointGutter({required this.notifier, required this.lines, required this.current, required this.marks, required this.onToggle});

  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  final int? current;
  final Map<int, GitMark> marks;
  final ValueChanged<int>? onToggle;

  @override
  State<_BreakpointGutter> createState() => _BreakpointGutterState();
}

class _BreakpointGutterState extends State<_BreakpointGutter> {
  final _hoverY = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _hoverY.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canToggle = widget.onToggle != null;
    return SizedBox(
      width: 18,
      child: MouseRegion(
        cursor: canToggle ? SystemMouseCursors.click : MouseCursor.defer,
        onHover: canToggle ? (e) => _hoverY.value = e.localPosition.dy : null,
        onExit: (_) => _hoverY.value = null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            for (final para in widget.notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
              if (d.localPosition.dy >= para.offset.dy && d.localPosition.dy < para.offset.dy + para.height) {
                widget.onToggle?.call(para.index);
                return;
              }
            }
          },
          child: CustomPaint(painter: _GutterPainter(widget.notifier, widget.lines, widget.current, widget.marks, _hoverY)),
        ),
      ),
    );
  }
}

class _GutterPainter extends CustomPainter {
  _GutterPainter(this.notifier, this.lines, this.current, this.marks, this.hoverY) : super(repaint: Listenable.merge([notifier, hoverY]));

  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  final int? current;
  final Map<int, GitMark> marks;
  final ValueListenable<double?> hoverY;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final hover = hoverY.value;
    final paint = Paint();
    for (final para in notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
      final top = para.offset.dy, height = para.height;
      // On the first row when wrapped, next to the line number.
      final middle = top + para.preferredLineHeight / 2;
      final mark = marks[para.index];
      if (mark != null) {
        paint.color = switch (mark) {
          GitMark.added => const Color(0xFF22C55E),
          GitMark.modified => const Color(0xFF3B82F6),
          GitMark.deleted => const Color(0xFFEF4444),
        };
        canvas.drawRect(
          mark == GitMark.deleted ? Rect.fromLTWH(0, top + height - 2, 6, 2) : Rect.fromLTWH(0, top, 3, height),
          paint,
        );
      }
      final hovered = hover != null && hover >= top && hover < top + height;
      if (lines.contains(para.index)) {
        paint.color = breakpointColor;
        canvas.drawCircle(Offset(10, middle), 5, paint);
        if (hovered) {
          canvas.drawCircle(
            Offset(10, middle),
            6.5,
            Paint()
              ..color = breakpointColor.withValues(alpha: .5)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      } else if (hovered) {
        paint.color = breakpointColor.withValues(alpha: .4);
        canvas.drawCircle(Offset(10, middle), 5, paint);
      }
      if (para.index == current) {
        paint.color = const Color(0xFFF59E0B);
        canvas.drawPath(
          Path()
            ..moveTo(5, middle - 6)
            ..lineTo(16, middle)
            ..lineTo(5, middle + 6)
            ..close(),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GutterPainter old) =>
      !setEquals(old.lines, lines) || old.current != current || !mapEquals(old.marks, marks);
}

class _BlamePainter extends CustomPainter {
  _BlamePainter(this.notifier, this.color, this.fontSize, this.blame, this.left) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final Color color;
  final double fontSize;
  final (String, Offset)? Function() blame;
  final double Function() left;

  @override
  void paint(Canvas canvas, Size size) {
    final found = blame();
    if (found == null) return;
    final (text, at) = found;
    final start = at.dx + 28;
    if (start < left() || start >= size.width) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: fontSize, height: 1.4, color: color.withValues(alpha: .75)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size.width - start - 12);
    painter.paint(canvas, Offset(start, at.dy));
    painter.dispose();
  }

  @override
  bool shouldRepaint(_BlamePainter old) => old.color != color || old.fontSize != fontSize;
}

class _BracketPainter extends CustomPainter {
  _BracketPainter(this.notifier, this.color, this.rects) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final Color color;
  final List<Rect> Function() rects;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: .18);
    final edge = Paint()
      ..color = color.withValues(alpha: .7)
      ..style = PaintingStyle.stroke;
    for (final r in rects()) {
      final box = RRect.fromRectAndRadius(r, const Radius.circular(2));
      canvas
        ..drawRRect(box, fill)
        ..drawRRect(box, edge);
    }
  }

  @override
  bool shouldRepaint(_BracketPainter old) => true;
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.notifier, this.rect) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final Rect? Function(Size size) rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect(size);
    if (r != null) canvas.drawRect(r, Paint()..color = const Color(0x33F59E0B));
  }

  @override
  bool shouldRepaint(_LinePainter old) => true;
}

/// A card under a text position, flipped above it when there's no room below.
class _Floating extends StatelessWidget {
  const _Floating({
    required this.at,
    required this.lineHeight,
    required this.width,
    required this.height,
    required this.child,
    this.shrink = false,
    this.above = false,
  });

  final Offset at;
  final double lineHeight, width, height;
  final bool shrink, above;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (_, box) {
        final below = above ? at.dy - lineHeight - height < 0 : at.dy + height <= box.maxHeight;
        final card = Material(
          elevation: 6,
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width, maxHeight: height),
            child: shrink ? child : SizedBox(width: width, height: height, child: child),
          ),
        );
        return Stack(
          children: [
            Positioned(
              left: at.dx.clamp(0, (box.maxWidth - width).clamp(0, double.infinity)),
              top: below ? at.dy : null,
              bottom: below ? null : box.maxHeight - at.dy + lineHeight,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 90),
                curve: Curves.easeOut,
                builder: (_, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(offset: Offset(0, (below ? -4 : 4) * (1 - t)), child: child),
                ),
                child: card,
              ),
            ),
          ],
        );
      },
    );
  }
}
