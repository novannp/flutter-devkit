import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

import 'debug_panel.dart' show breakpointColor;
import 'debugger.dart';
import 'editor_workspace.dart';
import 'find_panel.dart';
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

/// Draws a file's diagnostics as squiggles. Bound once per file, read fresh on every paint.
CodeLineSpanBuilder diagnosticsSpanBuilder(List<Diagnostic> Function() diagnostics) =>
    ({required context, required index, required codeLine, required textSpan, required style}) {
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
  late final _find = CodeFindController(widget.doc.controller);

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

  // Hover card.
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
    _ctrl.removeListener(_onEdit);
    widget.debugger.removeListener(_onDebugger);
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

  void reveal(int line, int column) {
    final last = _ctrl.lineCount - 1;
    final l = line.clamp(0, last);
    _ctrl.selection = CodeLineSelection.collapsed(index: l, offset: column.clamp(0, _ctrl.codeLines[l].length));
    _ctrl.makeCursorCenterIfInvisible();
    _focus.requestFocus();
  }

  // ------------------------------------------------------------- completion

  static final _wordBefore = RegExp(r'[A-Za-z0-9_$]*$');

  void _onEdit() {
    if (_applying || !mounted) return;
    final lines = _ctrl.codeLines;
    final changed = !identical(lines, _lastLines) && lines != _lastLines;
    final previous = _lastLines;
    _lastLines = lines;
    final sel = _ctrl.selection;
    if (changed && previous != null) _shiftBreakpoints(previous, lines, sel.extentIndex);
    if (!changed) {
      if (_popup && (!sel.isCollapsed || sel.extentIndex != _popupLine || sel.extentOffset < _wordStart)) _closePopup();
      return;
    }
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
  }

  void _closePopup() {
    _completionTimer?.cancel();
    _completionToken++;
    if (_popup && mounted) setState(() => _popup = false);
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
    if (mounted) widget.onReferences(refs);
  });

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

  /// Where the bottom-left of a character sits, in the stack's coordinates.
  Offset? _caretOffset(int line, int column) {
    final para = _paragraphAt(line);
    final origin = _fieldOrigin();
    if (para == null || origin == null) return null;
    final x = para.paragraph.getOffset(TextPosition(offset: column))?.dx ?? 0;
    return origin + para.offset + Offset(x, para.paragraph.preferredLineHeight);
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
    _hoverToken++;
    if (_hover != null) setState(() => _hover = null);
  }

  void _onHover(PointerHoverEvent e) {
    _clearHover();
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
    await _loadHover(line, col, local);
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
      _hover = parts.join('\n\n');
      _hoverAt = at;
    });
  }

  // ------------------------------------------------------------- build

  static const _rowHeight = 26.0;

  Widget _buildPopup(ColorScheme scheme) {
    final at = _caretOffset(_popupLine, _wordStart);
    if (at == null) return const SizedBox.shrink();
    return _Floating(
      at: at,
      lineHeight: _paragraphAt(_popupLine)?.paragraph.preferredLineHeight ?? 18,
      width: 460,
      height: (_shown.length * _rowHeight + 2).clamp(0, 262).toDouble(),
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
                    child: Text(
                      c.label,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final mode = _modes[p.extension(_doc.path).toLowerCase()];
    final theme = Map<String, TextStyle>.of(dark ? atomOneDarkTheme : atomOneLightTheme);
    return Listener(
      onPointerUp: (_) {
        if (!HardwareKeyboard.instance.isControlPressed) return;
        final sel = _ctrl.selection;
        // The tap has just placed the caret on the word that was clicked.
        unawaited(_goToDefinition(sel.extentIndex, sel.extentOffset));
      },
      child: MouseRegion(
        onHover: _onHover,
        onExit: (_) => _clearHover(),
        child: Stack(
          key: _stackKey,
          children: [
            CodeEditor(
              controller: _ctrl,
              focusNode: _focus,
              scrollController: _doc.scroll,
              findController: _find,
              wordWrap: false,
              autocompleteSymbols: true,
              padding: const EdgeInsets.only(left: 6, top: 4, bottom: 120, right: 16),
              style: CodeEditorStyle(
                fontFamily: 'Consolas',
                fontSize: 14,
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
                      textStyle: TextStyle(color: scheme.outline, fontFamily: 'Consolas', fontSize: 13),
                      focusedTextStyle: TextStyle(color: scheme.onSurface, fontFamily: 'Consolas', fontSize: 13),
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
                      return Rect.fromLTWH(origin.dx, origin.dy + para.offset.dy, size.width - origin.dx, para.preferredLineHeight);
                    }),
                  ),
                ),
              ),
            if (_popup) _buildPopup(scheme),
            if (_hover != null && _hoverAt != null)
              _Floating(
                at: _hoverAt!,
                lineHeight: 20,
                width: 560,
                height: 240,
                shrink: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(_hover!, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5)),
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
          if (d.localPosition.dy >= para.offset.dy && d.localPosition.dy < para.offset.dy + para.preferredLineHeight) {
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
      final top = para.offset.dy, height = para.preferredLineHeight;
      final middle = top + height / 2;
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
  });

  final Offset at;
  final double lineHeight, width, height;
  final bool shrink;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (_, box) {
        final below = at.dy + height <= box.maxHeight;
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
              child: card,
            ),
          ],
        );
      },
    );
  }
}
