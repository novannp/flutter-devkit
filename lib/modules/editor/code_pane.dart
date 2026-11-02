import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/gradle.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import '../../core/theme.dart';
import 'brackets.dart';
import 'debug_panel.dart' show breakpointColor;
import 'debugger.dart';
import 'editor_view.dart';
import 'editor_workspace.dart';
import 'find_panel.dart';
import 'markdown_view.dart';
import 'source_control.dart';

final _modes = <String, Mode>{
  '.dart': langDart,
  '.yaml': langYaml,
  '.yml': langYaml,
  '.json': langJson,
  '.arb': langJson,
  '.xml': langXml,
  '.html': langXml,
  '.plist': langXml,
  '.gradle': langGradle,
  '.kt': langKotlin,
  '.kts': langKotlin,
  '.java': langJava,
  '.swift': langSwift,
  '.c': langCpp,
  '.h': langCpp,
  '.cc': langCpp,
  '.cpp': langCpp,
  '.md': langMarkdown,
  '.sh': langBash,
  '.ps1': langPowershell,
  '.properties': langProperties,
  '.ini': langIni,
  '.toml': langIni,
  '.js': langJavascript,
  '.css': langCss,
};

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

/// Where [query] next appears after a position, wrapping past the end of the file. Null when it's nowhere.
(int, int)? nextOccurrence(List<String> lines, String query, int fromLine, int fromColumn) {
  if (query.isEmpty || lines.isEmpty) return null;
  for (var i = 0; i <= lines.length; i++) {
    final index = (fromLine + i) % lines.length;
    final at = lines[index].indexOf(query, i == 0 ? fromColumn.clamp(0, lines[index].length) : 0);
    if (at >= 0) return (index, at);
  }
  return null;
}

/// The VS Code keys re_editor binds differently. Ctrl+D matters most: its default deletes the line.
class _VsCodeShortcuts extends DefaultCodeShortcutsActivatorsBuilder {
  const _VsCodeShortcuts();

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) => switch (type) {
    CodeShortcutType.lineDelete => const [SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true)],
    CodeShortcutType.lineDeleteForward || CodeShortcutType.lineDeleteBackward => const [],
    CodeShortcutType.wordDeleteForward => const [SingleActivator(LogicalKeyboardKey.delete, control: true)],
    CodeShortcutType.wordDeleteBackward => const [SingleActivator(LogicalKeyboardKey.backspace, control: true)],
    CodeShortcutType.cursorMovePageStart => const [SingleActivator(LogicalKeyboardKey.home, control: true)],
    CodeShortcutType.cursorMovePageEnd => const [SingleActivator(LogicalKeyboardKey.end, control: true)],
    CodeShortcutType.replace => const [SingleActivator(LogicalKeyboardKey.keyH, control: true)],
    CodeShortcutType.multiLineComment => const [SingleActivator(LogicalKeyboardKey.keyA, shift: true, alt: true)],
    _ => super.build(type),
  };
}

const _lineComments = {
  '.dart': '//', '.kt': '//', '.kts': '//', '.java': '//', '.swift': '//', '.gradle': '//', '.js': '//',
  '.c': '//', '.h': '//', '.cc': '//', '.cpp': '//', '.yaml': '#', '.yml': '#', '.sh': '#', '.ps1': '#', '.toml': '#', '.properties': '#',
};

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
    _docsTimer?.cancel();
    _signatureTimer?.cancel();
    _ctrl.removeListener(_onEdit);
    widget.debugger.removeListener(_onDebugger);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    EditorView.listenable.removeListener(_onDebugger);
    widget.git.removeListener(_loadMarks);
    _doc.removeListener(_onDoc);
    _find.dispose();
    _focus.dispose();
    _popupScroll.dispose();
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
  }

  // Counts folded lines too: folding changes the list's length but not the file.
  static int _lineCount(CodeLines lines) {
    var n = 0;
    for (var i = 0; i < lines.length; i++) {
      n += lines[i].lineCount;
    }
    return n;
  }

  void _shiftBreakpoints(CodeLines before, CodeLines after, int cursor) {
    final delta = _lineCount(after) - _lineCount(before);
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
    _popup = false;
    _itemDocs = null;
    _signature = null;
    _hover = null;
    _overHover = false;
    _link = null;
    _pointer = null;
    _marks = const {};
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

  void _requestCompletion(int line, int column, int start) {
    _completionTimer?.cancel();
    final token = ++_completionToken;
    _completionTimer = Timer(const Duration(milliseconds: 60), () async {
      try {
        final items = await widget.workspace.completion(_doc, line, column);
        if (!mounted || token != _completionToken) return;
        _items = items;
        _incomplete = false;
        _popupLine = line;
        _wordStart = start;
        final sel = _ctrl.selection;
        if (!sel.isCollapsed || sel.extentIndex != line) return _closePopup();
        final text = _ctrl.codeLines[line].text;
        _filter(text.substring(start.clamp(0, text.length), sel.extentOffset.clamp(start, text.length)));
      } on Exception {
        // The server restarting or a timeout only means no suggestions this time.
      }
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
    widget.workspace.applyCompletion(_doc, resolved, line: line, start: start, end: _ctrl.selection.extentOffset);
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
    if (_popup) {
      if (key == LogicalKeyboardKey.arrowDown) return _handled(() => _moveSelection(1));
      if (key == LogicalKeyboardKey.arrowUp) return _handled(() => _moveSelection(-1));
      if (key == LogicalKeyboardKey.escape) return _handled(_closePopup);
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
        return _handled(() => _accept(_shown[_selected]));
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
        _requestCompletion(line, col, before.length - _wordBefore.firstMatch(before)![0]!.length);
      });
    }
    if (key == LogicalKeyboardKey.f12) {
      return _handled(() => hw.isShiftPressed ? _findReferences(line, col) : _goToDefinition(line, col));
    }
    if (key == LogicalKeyboardKey.f2) return _handled(() => _rename(line, col));
    if (key == LogicalKeyboardKey.f1) return _handled(() => _showHoverAtCaret(line, col));
    if (hw.isControlPressed && key == LogicalKeyboardKey.period) return _handled(() => _codeActions(line, col));
    return widget.onKey(event);
  }

  VoidCallback? _vsCodeKey(LogicalKeyboardKey key, HardwareKeyboard hw, {required bool readOnly}) {
    final ctrl = hw.isControlPressed, shift = hw.isShiftPressed, alt = hw.isAltPressed;
    if (ctrl && !shift && key == LogicalKeyboardKey.keyD) return _selectNextOccurrence;
    if (!readOnly) {
      if (ctrl && key == LogicalKeyboardKey.enter) return shift ? _insertLineAbove : _insertLineBelow;
      if (shift && alt && key == LogicalKeyboardKey.arrowDown) return () => _copyLines(down: true);
      if (shift && alt && key == LogicalKeyboardKey.arrowUp) return () => _copyLines(down: false);
      if (ctrl && !shift && key == LogicalKeyboardKey.bracketRight) return _ctrl.applyIndent;
      if (ctrl && !shift && key == LogicalKeyboardKey.bracketLeft) return _ctrl.applyOutdent;
    }
    if (ctrl && shift && (key == LogicalKeyboardKey.bracketLeft || key == LogicalKeyboardKey.braceLeft)) return _fold;
    if (ctrl && shift && (key == LogicalKeyboardKey.bracketRight || key == LogicalKeyboardKey.braceRight)) return _unfold;
    if (ctrl && key == LogicalKeyboardKey.arrowRight) {
      return shift ? _ctrl.extendSelectionToWordBoundaryForward : _ctrl.moveCursorToWordBoundaryForward;
    }
    if (ctrl && key == LogicalKeyboardKey.arrowLeft) {
      return shift ? _ctrl.extendSelectionToWordBoundaryBackward : _ctrl.moveCursorToWordBoundaryBackward;
    }
    if (key == LogicalKeyboardKey.f3) return shift ? _find.previousMatch : _find.nextMatch;
    return null;
  }

  /// One selection at a time: re_editor has no multiple cursors, so Ctrl+D moves on to the next match.
  void _selectNextOccurrence() {
    final sel = _ctrl.selection;
    if (sel.isCollapsed) {
      final text = _ctrl.codeLines[sel.extentIndex].text;
      final at = sel.extentOffset.clamp(0, text.length);
      final start = at - _wordBefore.firstMatch(text.substring(0, at))![0]!.length;
      final end = at + RegExp(r'^[A-Za-z0-9_$]*').firstMatch(text.substring(at))![0]!.length;
      if (start == end) return;
      _ctrl.selection = CodeLineSelection(baseIndex: sel.extentIndex, baseOffset: start, extentIndex: sel.extentIndex, extentOffset: end);
      return;
    }
    final query = _ctrl.selectedText;
    if (query.contains('\n')) return;
    final lines = [for (var i = 0; i < _ctrl.codeLines.length; i++) _ctrl.codeLines[i].text];
    final hit = nextOccurrence(lines, query, sel.endIndex, sel.endOffset);
    if (hit == null) return;
    _ctrl.selection = CodeLineSelection(baseIndex: hit.$1, baseOffset: hit.$2, extentIndex: hit.$1, extentOffset: hit.$2 + query.length);
    _ctrl.makeCursorCenterIfInvisible();
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
    final target = await widget.workspace.definition(_doc, line, col);
    if (!mounted) return;
    if (target == null) return _toast('No definition found here');
    widget.onTarget(target);
  });

  Future<void> _findReferences(int line, int col) => _guard(() async {
    final refs = await widget.workspace.references(_doc, line, col);
    if (!mounted) return;
    // The declaration counts as one of the results.
    if (refs.length <= 1) return _toast('No usages found');
    widget.onReferences(refs);
  });

  /// As in VS Code: Ctrl+click on a usage goes to its definition, on the declaration itself it lists the usages.
  Future<void> _ctrlClick(int line, int col) => _guard(() async {
    final target = await widget.workspace.definition(_doc, line, col);
    if (!mounted) return;
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
          style: const TextStyle(fontFamily: 'Consolas'),
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
    _hoverTimer?.cancel();
    _hoverHide?.cancel();
    _hoverHide = null;
    _hoverToken++;
    _overHover = false;
    if (_hover != null) setState(() => _hover = null);
  }

  // Pressing or releasing Ctrl with the mouse at rest has to update the link too.
  bool _onHardwareKey(KeyEvent e) {
    if (mounted && (e.logicalKey == LogicalKeyboardKey.controlLeft || e.logicalKey == LogicalKeyboardKey.controlRight)) _updateLink();
    return false;
  }

  void _updateLink() {
    (int, SemanticToken)? link;
    final at = _pointer;
    if (at != null && HardwareKeyboard.instance.isControlPressed && _doc.languageId == 'dart') {
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
    if (HardwareKeyboard.instance.isControlPressed) return;
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
    try {
      info = await widget.workspace.hover(_doc, line, col);
    } on Exception {
      info = null;
    }
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
    const mono = TextStyle(fontFamily: 'Consolas', fontSize: 13);
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
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mode = _modes[p.extension(_doc.path).toLowerCase()];
    final theme = Map<String, TextStyle>.of(dark ? atomOneDarkTheme : atomOneLightTheme);
    return Listener(
      onPointerDown: (e) {
        if (e.buttons != kSecondaryMouseButton || _doc.languageId != 'dart') return;
        final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
        final pos = box == null ? null : _positionAt(box.globalToLocal(e.position));
        if (pos != null) unawaited(_contextMenu(e.position, pos.$1, pos.$2));
      },
      onPointerUp: (e) {
        if (!HardwareKeyboard.instance.isControlPressed) return;
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
              // re_editor never drops its listeners from a controller it's taken off, so each document gets its own.
              key: ObjectKey(_doc),
              controller: _ctrl,
              focusNode: _focus,
              scrollController: _doc.scroll,
              findController: _find,
              readOnly: isLibrarySource(_doc.path),
              shortcutsActivatorsBuilder: const _VsCodeShortcuts(),
              commentFormatter: DefaultCodeCommentFormatter(
                singleLinePrefix: _lineComments[p.extension(_doc.path).toLowerCase()],
                multiLinePrefix: '/*',
                multiLineSuffix: '*/',
              ),
              wordWrap: EditorView.wordWrap.value,
              autocompleteSymbols: true,
              padding: const EdgeInsets.only(left: 6, top: 4, bottom: 120, right: 16),
              style: CodeEditorStyle(
                fontFamily: 'Cascadia Mono',
                fontFamilyFallback: const ['Consolas'],
                fontSize: EditorView.fontSize.value,
                fontHeight: 1.4,
                backgroundColor: scheme.surface,
                textColor: scheme.onSurface,
                cursorColor: scheme.primary,
                selectionColor: scheme.primary.withValues(alpha: .25),
                cursorLineColor: scheme.onSurface.withValues(alpha: .04),
                chunkIndicatorColor: scheme.outline,
                codeTheme: mode == null
                    ? null
                    : CodeHighlightTheme(languages: {'code': CodeHighlightThemeMode(mode: mode)}, theme: theme),
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
                      textStyle: TextStyle(color: scheme.outline, fontFamily: 'Consolas', fontSize: EditorView.fontSize.value - 1),
                      focusedTextStyle: TextStyle(color: scheme.onSurface, fontFamily: 'Consolas', fontSize: EditorView.fontSize.value - 1),
                    ),
                    DefaultCodeChunkIndicator(width: 18, controller: chunks, notifier: notifier),
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
                      final para = _paragraphAt(_currentLine!);
                      final origin = _fieldOrigin();
                      if (para == null || origin == null) return null;
                      return Rect.fromLTWH(origin.dx, origin.dy + para.offset.dy, size.width - origin.dx, para.height);
                    }),
                  ),
                ),
              ),
            if (_bracket != null && _indicator != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _BracketPainter(_indicator!, scheme.primary, () {
                      final (a, b) = _bracket!;
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
      Text(keys, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
    ],
  );
}

class _BreakpointGutter extends StatelessWidget {
  const _BreakpointGutter({required this.notifier, required this.lines, required this.current, required this.marks, required this.onToggle});

  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  final int? current;
  final Map<int, GitMark> marks;
  final ValueChanged<int>? onToggle;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 18,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        for (final para in notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
          if (d.localPosition.dy >= para.offset.dy && d.localPosition.dy < para.offset.dy + para.height) {
            onToggle?.call(para.index);
            return;
          }
        }
      },
      child: CustomPaint(painter: _GutterPainter(notifier, lines, current, marks)),
    ),
  );
}

class _GutterPainter extends CustomPainter {
  _GutterPainter(this.notifier, this.lines, this.current, this.marks) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final Set<int> lines;
  final int? current;
  final Map<int, GitMark> marks;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
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
      if (lines.contains(para.index)) {
        paint.color = breakpointColor;
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
