import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../core/theme.dart' show SyntaxColors;
import '../brackets.dart';
import 'code_model.dart';
import 'syntax.dart';
import '../../../core/platform_keys.dart';

export 'code_model.dart';

class CodeEditorStyle {
  const CodeEditorStyle({
    required this.fontFamily,
    this.fontFamilyFallback = const [],
    required this.fontSize,
    this.fontHeight = 1.4,
    required this.backgroundColor,
    required this.textColor,
    required this.cursorColor,
    required this.selectionColor,
    required this.cursorLineColor,
    required this.syntax,
  });

  final String fontFamily;
  final List<String> fontFamilyFallback;
  final double fontSize, fontHeight;
  final Color backgroundColor, textColor, cursorColor, selectionColor, cursorLineColor;
  final SyntaxColors syntax;

  TextStyle get text => TextStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: fontFamilyFallback,
    fontSize: fontSize,
    height: fontHeight,
    color: textColor,
  );
}

/// Where a shown line sits, for the gutter and for anything drawn on top of the code.
class CodeLineParagraph {
  CodeLineParagraph(this._painter, this.preferredLineHeight);

  final TextPainter _painter;
  final double preferredLineHeight;

  double get height => max(_painter.height, preferredLineHeight);

  Offset? getOffset(TextPosition position) => _painter.getOffsetForCaret(TextPosition(offset: position.offset.clamp(0, _painter.plainText.length), affinity: position.affinity), Rect.zero);

  TextPosition getPosition(Offset offset) => _painter.getPositionForOffset(offset);
}

class CodeLineRenderParagraph {
  const CodeLineRenderParagraph(this.index, this.paragraph, this.offset);

  final int index;
  final CodeLineParagraph paragraph;
  final Offset offset;

  double get preferredLineHeight => paragraph.preferredLineHeight;
  double get height => paragraph.height;
}

class CodeIndicatorValue {
  const CodeIndicatorValue(this.paragraphs, this.focusedIndex);

  final List<CodeLineRenderParagraph> paragraphs;
  final int focusedIndex;
}

class CodeIndicatorValueNotifier extends ValueNotifier<CodeIndicatorValue?> {
  CodeIndicatorValueNotifier() : super(null);
}

class CodeScrollController extends ChangeNotifier {
  double vertical = 0, horizontal = 0;
}

class CodeChunk {
  const CodeChunk(this.index, this.end);

  final int index, end;

  bool get canCollapse => end > index;
}

/// The blocks that can fold, from the bracket pairs that span lines.
class CodeChunkController extends ValueNotifier<List<CodeChunk>> {
  CodeChunkController(this._controller) : super(const []) {
    _controller.addListener(_onChanged);
    _analyze();
  }

  final CodeLineEditingController _controller;
  Timer? _debounce;
  CodeLines? _last;

  void _onChanged() {
    if (identical(_controller.codeLines, _last)) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), _analyze);
  }

  void _analyze() {
    final lines = _last = _controller.codeLines;
    final pairs = bracketPairs([for (var i = 0; i < lines.length; i++) lines[i].text]);
    final firstOnLine = <int, int>{};
    pairs.forEach((open, close) {
      if (close.$1 <= open.$1) return;
      // Several openers on a line: the outermost is the one worth folding.
      final known = firstOnLine[open.$1];
      if (known == null || close.$1 > known) firstOnLine[open.$1] = close.$1;
    });
    value = [for (final e in firstOnLine.entries.toList()..sort((a, b) => a.key - b.key)) CodeChunk(e.key, e.value)];
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    super.dispose();
  }
}

class CodeFindOption {
  const CodeFindOption({this.pattern = '', this.caseSensitive = false, this.regex = false});

  final String pattern;
  final bool caseSensitive, regex;
}

class CodeFindMatch {
  const CodeFindMatch(this.line, this.start, this.end);

  final int line, start, end;
}

class CodeFindResult {
  const CodeFindResult(this.matches, this.index);

  final List<CodeFindMatch> matches;
  final int index;
}

class CodeFindValue {
  const CodeFindValue(this.option, this.replaceMode, this.result);

  final CodeFindOption option;
  final bool replaceMode;
  final CodeFindResult? result;
}

class CodeFindController extends ValueNotifier<CodeFindValue?> {
  CodeFindController(this._controller) : super(null) {
    findInputController.addListener(_onPattern);
    _controller.addListener(_onText);
  }

  final CodeLineEditingController _controller;
  final findInputController = TextEditingController();
  final replaceInputController = TextEditingController();
  final findInputFocusNode = FocusNode(debugLabel: 'find');
  final replaceInputFocusNode = FocusNode(debugLabel: 'replace');
  CodeLines? _searched;

  void _open({required bool replace}) {
    final seed = _controller.selectedText;
    if (seed.isNotEmpty && !seed.contains('\n')) findInputController.text = seed;
    value = CodeFindValue(value?.option ?? const CodeFindOption(), replace, value?.result);
    _search();
    findInputController.selection = TextSelection(baseOffset: 0, extentOffset: findInputController.text.length);
    findInputFocusNode.requestFocus();
  }

  void findMode() => _open(replace: false);
  void replaceMode() => _open(replace: true);

  void toggleMode() {
    final v = value;
    if (v != null) value = CodeFindValue(v.option, !v.replaceMode, v.result);
  }

  void close() => value = null;

  void _onPattern() {
    if (value != null) _search();
  }

  void _onText() {
    if (value != null && !identical(_searched, _controller.codeLines)) _search();
  }

  void toggleCaseSensitive() => _setOption(caseSensitive: !(value?.option.caseSensitive ?? false));
  void toggleRegex() => _setOption(regex: !(value?.option.regex ?? false));

  void _setOption({bool? caseSensitive, bool? regex}) {
    final v = value;
    if (v == null) return;
    value = CodeFindValue(CodeFindOption(pattern: v.option.pattern, caseSensitive: caseSensitive ?? v.option.caseSensitive, regex: regex ?? v.option.regex), v.replaceMode, v.result);
    _search();
  }

  void _search() {
    final v = value;
    if (v == null) return;
    final lines = _searched = _controller.codeLines;
    final pattern = findInputController.text;
    final option = CodeFindOption(pattern: pattern, caseSensitive: v.option.caseSensitive, regex: v.option.regex);
    if (pattern.isEmpty) {
      value = CodeFindValue(option, v.replaceMode, null);
      return;
    }
    final Pattern matcher;
    try {
      matcher = RegExp(option.regex ? pattern : RegExp.escape(pattern), caseSensitive: option.caseSensitive);
    } on FormatException {
      value = CodeFindValue(option, v.replaceMode, const CodeFindResult([], 0));
      return;
    }
    final matches = <CodeFindMatch>[
      for (var i = 0; i < lines.length; i++)
        for (final m in matcher.allMatches(lines[i].text))
          if (m.end > m.start) CodeFindMatch(i, m.start, m.end),
    ];
    final s = _controller.selection;
    var index = matches.indexWhere((m) => m.line > s.startIndex || (m.line == s.startIndex && m.start >= s.startOffset));
    if (index < 0) index = 0;
    value = CodeFindValue(option, v.replaceMode, CodeFindResult(matches, index));
  }

  void _go(int delta) {
    final v = value, result = v?.result;
    if (v == null || result == null || result.matches.isEmpty) return;
    final index = (result.index + delta) % result.matches.length;
    value = CodeFindValue(v.option, v.replaceMode, CodeFindResult(result.matches, index));
    _select(result.matches[index]);
  }

  void _select(CodeFindMatch m) {
    _controller.selection = CodeLineSelection(baseIndex: m.line, baseOffset: m.start, extentIndex: m.line, extentOffset: m.end);
    _controller.makeCursorCenterIfInvisible();
  }

  void nextMatch() => _go(1);
  void previousMatch() => _go(-1);

  void replaceMatch() {
    final result = value?.result;
    if (result == null || result.matches.isEmpty) return;
    final m = result.matches[result.index];
    _controller.replaceSelection(replaceInputController.text, CodeLineSelection(baseIndex: m.line, baseOffset: m.start, extentIndex: m.line, extentOffset: m.end));
    _search();
    final next = value?.result;
    if (next != null && next.matches.isNotEmpty) _select(next.matches[next.index.clamp(0, next.matches.length - 1)]);
  }

  void replaceAllMatches() {
    final result = value?.result;
    if (result == null || result.matches.isEmpty) return;
    final byLine = <int, List<CodeFindMatch>>{};
    for (final m in result.matches) {
      byLine.putIfAbsent(m.line, () => []).add(m);
    }
    final lines = _controller.codeLines;
    final out = [
      for (var i = 0; i < lines.length; i++)
        () {
          var text = lines[i].text;
          for (final m in (byLine[i] ?? const <CodeFindMatch>[]).reversed) {
            text = text.replaceRange(m.start, m.end, replaceInputController.text);
          }
          return text;
        }(),
    ];
    _controller.text = out.join('\n');
    _search();
  }

  @override
  void dispose() {
    findInputController.removeListener(_onPattern);
    _controller.removeListener(_onText);
    findInputController.dispose();
    replaceInputController.dispose();
    findInputFocusNode.dispose();
    replaceInputFocusNode.dispose();
    super.dispose();
  }
}

typedef CodeIndicatorBuilder = Widget Function(BuildContext context, CodeLineEditingController controller, CodeChunkController chunks, CodeIndicatorValueNotifier notifier);

class CodeEditor extends StatefulWidget {
  const CodeEditor({
    super.key,
    this.controller,
    this.focusNode,
    this.scrollController,
    this.findController,
    this.language,
    this.lineComment,
    this.readOnly = false,
    this.wordWrap = false,
    this.padding = EdgeInsets.zero,
    required this.style,
    this.indicatorBuilder,
    this.findBuilder,
  });

  final CodeLineEditingController? controller;
  final FocusNode? focusNode;
  final CodeScrollController? scrollController;
  final CodeFindController? findController;
  final LanguageSpec? language;
  final String? lineComment;
  final bool readOnly, wordWrap;
  final EdgeInsets padding;
  final CodeEditorStyle style;
  final CodeIndicatorBuilder? indicatorBuilder;
  final Widget Function(BuildContext context, CodeFindController controller, bool readOnly)? findBuilder;

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CachedLine {
  _CachedLine(this.text, this.start, this.version, this.width, this.painter);

  final String text;
  final LexState start;
  final int version;
  final double width;
  final TextPainter painter;
}

class _CodeEditorState extends State<CodeEditor> with SingleTickerProviderStateMixin, TextInputClient implements DeltaTextInputClient {
  late CodeLineEditingController _ctrl = widget.controller ?? CodeLineEditingController();
  late final _ownsCtrl = widget.controller == null;
  late FocusNode _focus = widget.focusNode ?? FocusNode();
  late final _ownsFocus = widget.focusNode == null;
  late final CodeScrollController _scroll = widget.scrollController ?? CodeScrollController();
  late final _ownsScroll = widget.scrollController == null;
  late final _find = widget.findController ?? CodeFindController(_ctrl);
  late final _ownsFind = widget.findController == null;
  late final _chunks = CodeChunkController(_ctrl);
  final _indicator = CodeIndicatorValueNotifier();

  _RenderCode? _render;
  final _cache = <int, _CachedLine>{};

  // Replaced painters, kept until the next layout: the paragraphs last handed out still point at them.
  final _retired = <TextPainter>[];
  final _measured = <String, double>{};
  var _measuredWidth = -1.0;
  var _styleVersion = 0;

  // Layout.
  Size _size = Size.zero;
  double _lineHeight = 20, _charWidth = 8;
  List<int>? _visible;
  CodeLines? _visibleOf;
  List<double>? _tops;
  CodeLines? _topsOf;
  double _topsWidth = -1;
  double _contentHeight = 0, _contentWidth = 0;
  double _maxLineWidth = 0;
  CodeLines? _maxWidthOf;

  // Syntax states, up to where they've been worked out.
  final _states = <LexState>[const LexState.code()];

  // Caret. It glides to where it's going and fades as it blinks, both driven by the ticker.
  Timer? _blink;
  var _caretOn = true;
  var _caretAlpha = 1.0;
  Offset? _caretDrawn;
  Offset? _caretTarget;

  // Smooth scrolling.
  late final Ticker _ticker = createTicker(_onTick);
  double? _targetVertical;

  // Mouse.
  DateTime _lastDown = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastDownAt = Offset.zero;
  var _clicks = 0;
  CodeLineSelection? _anchor;
  var _dragging = false;
  var _draggingThumb = false;
  Offset? _dragPointer;
  Timer? _dragScroll;

  // Text input.
  TextInputConnection? _input;
  int? _viewId;
  var _applyingInput = false;
  TextRange _composing = TextRange.empty;

  EdgeInsets get _pad => widget.padding;

  @override
  void initState() {
    super.initState();
    _bind();
    _focus.addListener(_onFocus);
    _find.addListener(_onFind);
    _scroll.addListener(_markPaint);
    if (_focus.hasFocus) _onFocus();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
    if (_focus.hasFocus) _openInput();
  }

  void _bind() {
    _ctrl.addListener(_onController);
    _ctrl.onReveal = _reveal;
  }

  @override
  void didUpdateWidget(CodeEditor old) {
    super.didUpdateWidget(old);
    if (old.style.fontSize != widget.style.fontSize ||
        old.style.fontFamily != widget.style.fontFamily ||
        !identical(old.style.syntax, widget.style.syntax) ||
        old.style.textColor != widget.style.textColor ||
        old.wordWrap != widget.wordWrap ||
        old.language != widget.language) {
      _styleVersion++;
      _clearCache();
      _measured.clear();
      _topsOf = null;
      _maxLineWidth = 0;
      _maxWidthOf = null;
      _states
        ..clear()
        ..add(const LexState.code());
      if (!widget.wordWrap) _scroll.horizontal = 0;
    }
    if (old.controller != widget.controller && widget.controller != null) {
      _ctrl.removeListener(_onController);
      if (_ctrl.onReveal == _reveal) _ctrl.onReveal = null;
      _ctrl = widget.controller!;
      _bind();
    }
    if (old.focusNode != widget.focusNode && widget.focusNode != null) {
      _focus.removeListener(_onFocus);
      _focus = widget.focusNode!;
      _focus.addListener(_onFocus);
    }
    _render?.markNeedsLayout();
  }

  @override
  void dispose() {
    _blink?.cancel();
    _dragScroll?.cancel();
    _ticker.dispose();
    _closeInput();
    _ctrl.removeListener(_onController);
    if (_ctrl.onReveal == _reveal) _ctrl.onReveal = null;
    _focus.removeListener(_onFocus);
    _find.removeListener(_onFind);
    _scroll.removeListener(_markPaint);
    _chunks.dispose();
    _indicator.dispose();
    _clearCache();
    _disposeRetired();
    if (_ownsFind) _find.dispose();
    if (_ownsCtrl) _ctrl.dispose();
    if (_ownsFocus) _focus.dispose();
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  void _clearCache() {
    _retired.addAll(_cache.values.map((c) => c.painter));
    _cache.clear();
  }

  void _disposeRetired() {
    for (final painter in _retired) {
      painter.dispose();
    }
    _retired.clear();
  }

  void _markPaint() => _render?.markNeedsLayout();

  void _onFind() {
    if (mounted) setState(() {});
    _render?.markNeedsPaint();
    // Closing the panel hands the keyboard back to the code.
    if (_find.value == null && !_focus.hasFocus && (_find.findInputFocusNode.hasFocus || _find.replaceInputFocusNode.hasFocus)) _focus.requestFocus();
  }

  CodeLines? _lastLines;
  var _revealAfterEdit = false;

  void _onController() {
    if (!mounted) return;
    final lines = _ctrl.codeLines;
    final textChanged = !identical(lines, _lastLines);
    _lastLines = lines;
    if (textChanged && _focus.hasFocus) _revealAfterEdit = true;
    _restartBlink();
    _render?.markNeedsLayout();
    _syncInput();
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      _openInput();
      _restartBlink();
    } else {
      _closeInput();
      _blink?.cancel();
      _caretOn = false;
    }
    _render?.markNeedsPaint();
  }

  void _restartBlink() {
    _blink?.cancel();
    _caretOn = true;
    _caretAlpha = 1;
    if (!_focus.hasFocus) return;
    _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
      _caretOn = !_caretOn;
      _wake();
    });
  }

  // ------------------------------------------------------------- text input

  void _openInput() {
    if (widget.readOnly || _viewId == null || (_input?.attached ?? false)) return;
    _input = TextInput.attach(
      this,
      TextInputConfiguration(
        // The Windows engine refuses a client without one, and then no typed text arrives.
        viewId: _viewId,
        inputType: TextInputType.multiline,
        inputAction: TextInputAction.newline,
        enableDeltaModel: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    );
    _input!.show();
    _syncInput();
  }

  void _closeInput() {
    _input?.close();
    _input = null;
    _composing = TextRange.empty;
  }

  /// The system only ever sees the caret's line: enough for typing and for an input method.
  TextEditingValue get _inputValue {
    final s = _ctrl.selection;
    final line = _ctrl.codeLines[s.extentIndex].text;
    return TextEditingValue(
      text: line,
      selection: s.startIndex == s.endIndex
          ? TextSelection(baseOffset: s.baseOffset, extentOffset: s.extentOffset)
          : TextSelection.collapsed(offset: s.extentOffset),
      composing: _composing,
    );
  }

  void _syncInput() {
    if (_applyingInput || !(_input?.attached ?? false)) return;
    _input!.setEditingState(_inputValue);
    final render = _render;
    if (render == null || !render.attached || !render.hasSize) return;
    _input!.setEditableSizeAndTransform(render.size, render.getTransformTo(null));
    final caret = _caretRect(_ctrl.selection.extentIndex, _ctrl.selection.extentOffset);
    if (caret != null) _input!.setCaretRect(caret);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _inputValue;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    // Only the delta form is asked for; a plain update has nothing to add.
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    if (widget.readOnly) return;
    _applyingInput = true;
    for (final d in deltas) {
      _composing = d.composing;
      final line = _ctrl.selection.extentIndex;
      switch (d) {
        case TextEditingDeltaInsertion():
          if (d.textInserted == '\n') {
            _ctrl.applyNewLine();
          } else if (d.textInserted.isNotEmpty) {
            _ctrl.insertTyped(d.textInserted);
          }
        case TextEditingDeltaReplacement():
          _ctrl.replaceSelection(
            d.replacementText,
            CodeLineSelection(baseIndex: line, baseOffset: d.replacedRange.start, extentIndex: line, extentOffset: d.replacedRange.end),
          );
        case TextEditingDeltaDeletion():
          _ctrl.replaceSelection('', CodeLineSelection(baseIndex: line, baseOffset: d.deletedRange.start, extentIndex: line, extentOffset: d.deletedRange.end));
        case TextEditingDeltaNonTextUpdate():
          break;
      }
    }
    _applyingInput = false;
    _syncInput();
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline && !widget.readOnly) _ctrl.applyNewLine();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _input = null;
  }

  // ------------------------------------------------------------- layout

  TextStyle get _textStyle => widget.style.text;

  StrutStyle get _strut => StrutStyle(
    fontFamily: widget.style.fontFamily,
    fontFamilyFallback: widget.style.fontFamilyFallback,
    fontSize: widget.style.fontSize,
    height: widget.style.fontHeight,
    forceStrutHeight: true,
  );

  double get _wrapWidth => widget.wordWrap ? max(40, _size.width - _pad.horizontal - 10) : double.infinity;

  LexState _stateBefore(int line) {
    final dirty = _ctrl.dirtyFrom;
    if (dirty + 1 < _states.length) _states.length = dirty + 1;
    _ctrl.dirtyFrom = 1 << 30;
    final spec = widget.language;
    if (spec == null) return const LexState.code();
    final lines = _ctrl.codeLines;
    while (_states.length <= line) {
      final at = _states.length - 1;
      _states.add(tokenizeLine(lines[at].text, spec, _states[at]).$2);
    }
    return _states[line];
  }

  TextPainter _paragraphFor(int line) {
    final lines = _ctrl.codeLines;
    final codeLine = lines[line];
    final start = _stateBefore(line);
    final version = _ctrl.paintVersion * 1000 + _styleVersion;
    final width = _wrapWidth;
    final cached = _cache[line];
    if (cached != null && cached.text == codeLine.text && cached.start.same(start) && cached.version == version && cached.width == width) {
      return cached.painter;
    }
    if (cached != null) _retired.add(cached.painter);
    final style = _textStyle;
    final spec = widget.language;
    var span = spec == null
        ? TextSpan(text: codeLine.text, style: style)
        : spanForLine(codeLine.text, tokenizeLine(codeLine.text, spec, start).$1, widget.style.syntax, style);
    final build = _ctrl.spanBuilder;
    if (build != null) span = build(context: context, index: line, codeLine: codeLine, textSpan: span, style: style);
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr, strutStyle: _strut, textScaler: TextScaler.noScaling);
    if (width.isFinite) {
      painter.layout(maxWidth: width);
    } else {
      painter.layout();
    }
    _cache[line] = _CachedLine(codeLine.text, start, version, width, painter);
    return painter;
  }

  double _heightOf(String text) {
    final width = _wrapWidth;
    if (width != _measuredWidth) {
      _measured.clear();
      _measuredWidth = width;
    }
    return _measured.putIfAbsent(text, () {
      final p = TextPainter(text: TextSpan(text: text, style: _textStyle), textDirection: TextDirection.ltr, strutStyle: _strut, textScaler: TextScaler.noScaling)
        ..layout(maxWidth: width);
      final h = max(p.height, _lineHeight);
      p.dispose();
      return h;
    });
  }

  void _updateMetrics() {
    final m = TextPainter(text: TextSpan(text: 'M', style: _textStyle), textDirection: TextDirection.ltr, strutStyle: _strut, textScaler: TextScaler.noScaling)..layout();
    _lineHeight = max(m.height, 1);
    _charWidth = max(m.width, 1);
    m.dispose();
  }

  void _updateVisible() {
    final lines = _ctrl.codeLines;
    if (identical(lines, _visibleOf)) return;
    _visibleOf = lines;
    final folded = _ctrl.foldedRanges;
    if (folded.isEmpty) {
      _visible = null;
      return;
    }
    final out = <int>[];
    var i = 0;
    while (i < lines.length) {
      out.add(i);
      final end = folded[i];
      i = end == null ? i + 1 : end + 1;
    }
    _visible = out;
  }

  int get _visibleCount => _visible?.length ?? _ctrl.codeLines.length;
  int _lineAtVisual(int visual) => _visible == null ? visual : _visible![visual.clamp(0, _visible!.length - 1)];

  int _visualOf(int line) {
    final visible = _visible;
    if (visible == null) return line;
    var low = 0, high = visible.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (visible[mid] <= line) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  void _updateTops() {
    if (!widget.wordWrap) {
      _tops = null;
      return;
    }
    final lines = _ctrl.codeLines;
    final width = _wrapWidth;
    if (identical(lines, _topsOf) && width == _topsWidth && _tops != null) return;
    _topsOf = lines;
    _topsWidth = width;
    final tops = List<double>.filled(_visibleCount + 1, 0);
    for (var v = 0; v < _visibleCount; v++) {
      tops[v + 1] = tops[v] + _heightOf(lines[_lineAtVisual(v)].text);
    }
    _tops = tops;
  }

  double _topOfVisual(int visual) => _tops == null ? visual * _lineHeight : _tops![visual.clamp(0, _tops!.length - 1)];

  int _visualAtY(double y) {
    final count = _visibleCount;
    if (count == 0) return 0;
    final tops = _tops;
    if (tops == null) return (y / _lineHeight).floor().clamp(0, count - 1);
    var low = 0, high = count - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (tops[mid] <= y) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  double get _maxVertical => max(0, _contentHeight - _size.height);
  double get _maxHorizontal => widget.wordWrap ? 0 : max(0, _contentWidth - _size.width);

  /// Runs in the render object's layout: positions everything for this size and scroll offset.
  void layoutCode(Size size) {
    _size = size;
    _updateMetrics();
    _updateVisible();
    _updateTops();
    final total = _tops == null ? _visibleCount * _lineHeight : _tops!.last;
    _contentHeight = _pad.vertical + total;
    _scroll.vertical = _scroll.vertical.clamp(0.0, _maxVertical);
    if (_revealAfterEdit || _ctrl.takePendingReveal()) {
      final center = !_revealAfterEdit && _ctrl.pendingRevealCenter;
      _revealAfterEdit = false;
      _revealNow(center: center);
    }
    final first = _visualAtY(_scroll.vertical - _pad.top);
    final last = _visualAtY(_scroll.vertical + size.height - _pad.top);
    final paragraphs = <CodeLineRenderParagraph>[];
    final lines = _ctrl.codeLines;
    if (!identical(lines, _maxWidthOf)) {
      _maxWidthOf = lines;
      _maxLineWidth = 0;
    }
    final keep = <int>{};
    for (var v = first; v <= last && v < _visibleCount; v++) {
      final line = _lineAtVisual(v);
      keep.add(line);
      final painter = _paragraphFor(line);
      _maxLineWidth = max(_maxLineWidth, painter.width);
      paragraphs.add(
        CodeLineRenderParagraph(
          line,
          CodeLineParagraph(painter, _lineHeight),
          Offset(_pad.left - _scroll.horizontal, _pad.top + _topOfVisual(v) - _scroll.vertical),
        ),
      );
    }
    _contentWidth = _pad.horizontal + _maxLineWidth + 40;
    _scroll.horizontal = _scroll.horizontal.clamp(0.0, _maxHorizontal);
    _cache.removeWhere((line, c) {
      if (keep.contains(line) || (line - _ctrl.selection.extentIndex).abs() < 2) return false;
      _retired.add(c.painter);
      return true;
    });
    _indicator.value = CodeIndicatorValue(paragraphs, _ctrl.selection.extentIndex);
    _disposeRetired();
  }

  /// A caret's box in the field's coordinates; null for a line out of sight in a fold.
  Rect? _caretRect(int line, int column) {
    final visual = _visualOf(line);
    if (_lineAtVisual(visual) != line) return null;
    final painter = _paragraphFor(line);
    final at = painter.getOffsetForCaret(TextPosition(offset: column.clamp(0, painter.plainText.length)), Rect.zero);
    return Rect.fromLTWH(_pad.left - _scroll.horizontal + at.dx, _pad.top + _topOfVisual(visual) - _scroll.vertical + at.dy, 2, _lineHeight);
  }

  void _reveal({required bool center}) {
    if (_size == Size.zero) {
      _revealAfterEdit = true;
      return;
    }
    _revealNow(center: center);
    _render?.markNeedsLayout();
  }

  void _revealNow({required bool center}) {
    if (_size == Size.zero) return;
    final s = _ctrl.selection;
    final visual = _visualOf(s.extentIndex);
    final painter = _lineAtVisual(visual) == s.extentIndex ? _paragraphFor(s.extentIndex) : null;
    final at = painter?.getOffsetForCaret(TextPosition(offset: s.extentOffset.clamp(0, painter.plainText.length)), Rect.zero) ?? Offset.zero;
    final top = _pad.top + _topOfVisual(visual) + at.dy;
    final bottom = top + _lineHeight;
    final view = _size.height;
    // Measured against where a scroll under way is heading, so a run of keys doesn't fight it.
    final current = _targetVertical ?? _scroll.vertical;
    if (top < current || bottom > current + view) {
      final next = (center ? top - view / 2 + _lineHeight / 2 : (top < current ? top - _lineHeight : bottom - view + _lineHeight)).clamp(0.0, _maxVertical);
      // Nearby the view glides along; a jump across the file goes straight there.
      if (!center && (next - _scroll.vertical).abs() < view * 1.5) {
        _targetVertical = next;
        _wake();
      } else {
        _targetVertical = null;
        _scroll.vertical = next;
      }
    }
    _scroll.vertical = _scroll.vertical.clamp(0.0, _maxVertical);
    if (!widget.wordWrap) {
      final x = _pad.left + at.dx;
      final margin = _charWidth * 4;
      if (x < _scroll.horizontal + margin) {
        _scroll.horizontal = max(0, x - margin);
      } else if (x > _scroll.horizontal + _size.width - margin) {
        _scroll.horizontal = x - _size.width + margin;
        _contentWidth = max(_contentWidth, x + margin);
      }
    }
  }

  (int, int) _positionAt(Offset local) {
    final y = local.dy + _scroll.vertical - _pad.top;
    final visual = _visualAtY(y);
    // The fold map is rebuilt at layout, so it can run past a file that just got shorter.
    final line = _lineAtVisual(visual).clamp(0, _ctrl.lineCount - 1);
    if (y < 0) return (line, 0);
    final painter = _paragraphFor(line);
    final inLine = Offset(local.dx + _scroll.horizontal - _pad.left, y - _topOfVisual(visual));
    return (line, painter.getPositionForOffset(inLine).offset);
  }

  // ------------------------------------------------------------- painting

  void paintCode(Canvas canvas, Offset offset, Size size) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = widget.style.backgroundColor;
    canvas.drawRect(Offset.zero & size, paint);
    final value = _indicator.value;
    final paragraphs = value?.paragraphs ?? const <CodeLineRenderParagraph>[];
    final all = [_ctrl.selection, ..._ctrl.extraSelections];

    paint.color = widget.style.cursorLineColor;
    for (final s in all) {
      if (!s.isCollapsed) continue;
      for (final para in paragraphs) {
        if (para.index == s.extentIndex) canvas.drawRect(Rect.fromLTWH(0, para.offset.dy, size.width, para.height), paint);
      }
    }

    final find = _find.value?.result;
    if (find != null && find.matches.isNotEmpty) {
      final current = find.matches[find.index.clamp(0, find.matches.length - 1)];
      for (final para in paragraphs) {
        for (final m in _matchesOn(find, para.index)) {
          paint.color = identical(m, current) ? const Color(0x99F59E0B) : const Color(0x44F59E0B);
          _paintRange(canvas, para, m.start, m.end, paint);
        }
      }
    }

    paint.color = widget.style.selectionColor;
    for (final s in all) {
      if (s.isCollapsed) continue;
      for (final para in paragraphs) {
        if (para.index < s.startIndex || para.index > s.endIndex) continue;
        final length = _ctrl.codeLines[para.index].length;
        final from = para.index == s.startIndex ? s.startOffset : 0;
        final to = para.index == s.endIndex ? s.endOffset : length;
        _paintRange(canvas, para, from, to, paint, lineBreak: para.index < s.endIndex);
      }
    }

    for (final para in paragraphs) {
      para.paragraph._painter.paint(canvas, para.offset);
      final foldEnd = _ctrl.foldedRanges[para.index];
      if (foldEnd != null) _paintFoldMark(canvas, para, foldEnd);
    }

    if (_focus.hasFocus && _caretAlpha > 0) {
      paint.color = widget.style.cursorColor.withValues(alpha: _caretAlpha);
      final scrolled = Offset(_scroll.horizontal, _scroll.vertical);
      for (final s in all) {
        for (final para in paragraphs) {
          if (para.index != s.extentIndex) continue;
          final length = _ctrl.codeLines[para.index].length;
          final at = para.offset + para.paragraph._painter.getOffsetForCaret(TextPosition(offset: s.extentOffset.clamp(0, length)), Rect.zero);
          var drawn = at;
          if (identical(s, all.first)) {
            // In document coordinates, so scrolling doesn't read as the caret moving.
            final target = at + scrolled;
            if (_caretTarget != target) {
              final previous = _caretTarget;
              _caretTarget = target;
              // A short hop glides; a jump across the file just goes there.
              if (previous != null && (target - previous).dy.abs() < _lineHeight * 4) {
                _caretDrawn ??= previous;
                SchedulerBinding.instance.addPostFrameCallback((_) => _wake());
              } else {
                _caretDrawn = null;
              }
            }
            if (_caretDrawn != null) drawn = _caretDrawn! - scrolled;
          }
          canvas.drawRect(Rect.fromLTWH(drawn.dx, drawn.dy, 2, _lineHeight), paint);
        }
      }
    }

    _paintScrollbars(canvas, size, paint);
    canvas.restore();
  }

  Iterable<CodeFindMatch> _matchesOn(CodeFindResult result, int line) sync* {
    final matches = result.matches;
    var low = 0, high = matches.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (matches[mid].line < line) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < matches.length && matches[i].line == line; i++) {
      yield matches[i];
    }
  }

  void _paintRange(Canvas canvas, CodeLineRenderParagraph para, int from, int to, Paint paint, {bool lineBreak = false}) {
    final painter = para.paragraph._painter;
    if (from < to) {
      for (final box in painter.getBoxesForSelection(TextSelection(baseOffset: from, extentOffset: to))) {
        canvas.drawRect(box.toRect().shift(para.offset), paint);
      }
    }
    if (lineBreak) {
      final at = painter.getOffsetForCaret(TextPosition(offset: to), Rect.zero);
      canvas.drawRect(Rect.fromLTWH(para.offset.dx + at.dx, para.offset.dy + at.dy, _charWidth / 2, _lineHeight), paint);
    }
  }

  void _paintFoldMark(Canvas canvas, CodeLineRenderParagraph para, int end) {
    final painter = para.paragraph._painter;
    final mark = TextPainter(
      text: TextSpan(text: ' ⋯ ', style: _textStyle.copyWith(color: widget.style.cursorColor, backgroundColor: widget.style.selectionColor)),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    mark.paint(canvas, para.offset + Offset(painter.width + _charWidth / 2, 0));
    mark.dispose();
  }

  void _paintScrollbars(Canvas canvas, Size size, Paint paint) {
    paint.color = widget.style.textColor.withValues(alpha: .18);
    if (_contentHeight > size.height) {
      final (top, height) = _thumb(size.height, _contentHeight, _scroll.vertical);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(size.width - 9, top, 7, height), const Radius.circular(4)), paint);
    }
    if (_maxHorizontal > 0) {
      final (left, width) = _thumb(size.width, _contentWidth, _scroll.horizontal);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(left, size.height - 8, width, 6), const Radius.circular(3)), paint);
    }
  }

  (double, double) _thumb(double view, double content, double offset) {
    final length = max(24.0, view * view / content);
    final travel = view - length;
    final position = content > view ? offset / (content - view) * travel : 0.0;
    return (position, length);
  }

  // ------------------------------------------------------------- scrolling

  void _wake() {
    if (mounted && !_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration _) {
    var moving = false;
    final target = _targetVertical;
    if (target != null) {
      final distance = target - _scroll.vertical;
      if (distance.abs() < 0.5) {
        _scroll.vertical = target;
        _targetVertical = null;
      } else {
        _scroll.vertical += distance * 0.32;
        moving = true;
      }
      _render?.markNeedsLayout();
    }
    final drawn = _caretDrawn, caret = _caretTarget;
    if (drawn != null && caret != null) {
      final left = caret - drawn;
      if (left.distance < 0.5) {
        _caretDrawn = null;
      } else {
        _caretDrawn = drawn + left * 0.5;
        moving = true;
      }
      _render?.markNeedsPaint();
    }
    final alpha = _caretOn ? 1.0 : 0.0;
    if (_caretAlpha != alpha) {
      final step = (alpha - _caretAlpha) * 0.3;
      _caretAlpha = step.abs() < 0.02 ? alpha : _caretAlpha + step;
      moving = moving || _caretAlpha != alpha;
      _render?.markNeedsPaint();
    }
    if (!moving) _ticker.stop();
  }

  void _scrollBy(double dx, double dy) {
    if (dy != 0) {
      _targetVertical = ((_targetVertical ?? _scroll.vertical) + dy).clamp(0.0, _maxVertical);
      _wake();
    }
    if (dx != 0) {
      _scroll.horizontal = (_scroll.horizontal + dx).clamp(0.0, _maxHorizontal);
      _render?.markNeedsLayout();
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      _scrollBy(shift ? event.scrollDelta.dy : event.scrollDelta.dx, shift ? 0 : event.scrollDelta.dy);
    }
  }

  // ------------------------------------------------------------- mouse

  void _onPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton && e.kind == PointerDeviceKind.mouse) return;
    if (!_focus.hasFocus) _focus.requestFocus();
    if (_size.width - e.localPosition.dx < 12 && _contentHeight > _size.height) {
      _draggingThumb = true;
      _dragThumbTo(e.localPosition.dy);
      return;
    }
    final now = DateTime.now();
    final close = (e.localPosition - _lastDownAt).distance < 4 && now.difference(_lastDown).inMilliseconds < 400;
    _clicks = close ? _clicks % 3 + 1 : 1;
    _lastDown = now;
    _lastDownAt = e.localPosition;
    final (line, col) = _positionAt(e.localPosition);
    final keys = HardwareKeyboard.instance;
    if (isAltReallyPressed()) {
      _ctrl.addCursor(CodeLineSelection.collapsed(index: line, offset: col));
      return;
    }
    if (keys.isShiftPressed) {
      final s = _ctrl.selection;
      _ctrl.selection = CodeLineSelection(baseIndex: s.baseIndex, baseOffset: s.baseOffset, extentIndex: line, extentOffset: col);
      _anchor = _ctrl.selection;
    } else if (_clicks == 2) {
      final text = _ctrl.codeLines[line].text;
      var start = col, end = col;
      bool word(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);
      while (start > 0 && word(text[start - 1])) {
        start--;
      }
      while (end < text.length && word(text[end])) {
        end++;
      }
      _ctrl.selection = CodeLineSelection(baseIndex: line, baseOffset: start, extentIndex: line, extentOffset: end);
      _anchor = _ctrl.selection;
    } else if (_clicks == 3) {
      _ctrl.selectLine(line);
      _anchor = _ctrl.selection;
    } else {
      _ctrl.selection = CodeLineSelection.collapsed(index: line, offset: col);
      _anchor = _ctrl.selection;
    }
    _dragging = true;
  }

  void _dragThumbTo(double y) {
    final (_, length) = _thumb(_size.height, _contentHeight, _scroll.vertical);
    final travel = _size.height - length;
    if (travel <= 0) return;
    _targetVertical = null;
    _scroll.vertical = ((y - length / 2) / travel * _maxVertical).clamp(0.0, _maxVertical);
    _render?.markNeedsLayout();
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_draggingThumb) return _dragThumbTo(e.localPosition.dy);
    if (!_dragging) return;
    _dragPointer = e.localPosition;
    _extendTo(e.localPosition);
    // Past the edge the view keeps going, so a selection can run longer than the screen.
    final outside = e.localPosition.dy < 0 || e.localPosition.dy > _size.height;
    if (outside) {
      _dragScroll ??= Timer.periodic(const Duration(milliseconds: 50), (_) {
        final at = _dragPointer;
        if (at == null || !mounted) return;
        final dy = at.dy < 0 ? at.dy : at.dy - _size.height;
        _scroll.vertical = (_scroll.vertical + dy.clamp(-60, 60)).clamp(0.0, _maxVertical);
        _extendTo(at);
      });
    } else {
      _dragScroll?.cancel();
      _dragScroll = null;
    }
  }

  void _extendTo(Offset local) {
    final anchor = _anchor;
    if (anchor == null) return;
    final (line, col) = _positionAt(local);
    final next = CodeLineSelection(baseIndex: anchor.baseIndex, baseOffset: anchor.baseOffset, extentIndex: line, extentOffset: col);
    if (next != _ctrl.selection) _ctrl.selection = next;
  }

  void _onPointerUp(PointerEvent e) {
    _dragging = false;
    _draggingThumb = false;
    _dragPointer = null;
    _dragScroll?.cancel();
    _dragScroll = null;
  }

  // ------------------------------------------------------------- keyboard

  KeyEventResult _handled(void Function() action) {
    action();
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _find.value != null) {
      return _handled(() {
        _find.close();
        _focus.requestFocus();
      });
    }
    // Keys typed in the find panel below this node belong to its fields.
    if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
    final hw = HardwareKeyboard.instance;
    final ctrl = hw.isPrimaryPressed, shift = hw.isShiftPressed, alt = hw.isAltPressed;
    final edit = !widget.readOnly;
    final c = _ctrl;

    if (key == LogicalKeyboardKey.escape) {
      if (c.hasExtraCursors) return _handled(c.clearExtraCursors);
      if (!c.selection.isCollapsed) return _handled(c.cancelSelection);
      return KeyEventResult.ignored;
    }
    if (Platform.isMacOS && ctrl) {
      if (key == LogicalKeyboardKey.arrowLeft) return _handled(() => c.moveToLineStart(extend: shift));
      if (key == LogicalKeyboardKey.arrowRight) return _handled(() => c.moveToLineEnd(extend: shift));
      if (key == LogicalKeyboardKey.arrowUp) return _handled(() => c.moveToDocumentEdge(start: true, extend: shift));
      if (key == LogicalKeyboardKey.arrowDown) return _handled(() => c.moveToDocumentEdge(start: false, extend: shift));
    }
    if (Platform.isMacOS && alt && edit) {
      if (key == LogicalKeyboardKey.backspace) return _handled(c.deleteWordBackward);
      if (key == LogicalKeyboardKey.delete) return _handled(c.deleteWordForward);
    }
    if (key == LogicalKeyboardKey.arrowLeft && !alt) return _handled(() => c.moveHorizontal(-1, extend: shift));
    if (key == LogicalKeyboardKey.arrowRight && !alt) return _handled(() => c.moveHorizontal(1, extend: shift));
    if (key == LogicalKeyboardKey.arrowUp) {
      if (alt) return edit ? _handled(c.moveSelectionLinesUp) : KeyEventResult.ignored;
      if (ctrl) return _handled(() => _scrollBy(0, -_lineHeight));
      return _handled(() => c.moveVertical(-1, extend: shift));
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (alt) return edit ? _handled(c.moveSelectionLinesDown) : KeyEventResult.ignored;
      if (ctrl) return _handled(() => _scrollBy(0, _lineHeight));
      return _handled(() => c.moveVertical(1, extend: shift));
    }
    if (key == LogicalKeyboardKey.home) return _handled(ctrl ? () => c.moveToDocumentEdge(start: true, extend: shift) : () => c.moveToLineStart(extend: shift));
    if (key == LogicalKeyboardKey.end) return _handled(ctrl ? () => c.moveToDocumentEdge(start: false, extend: shift) : () => c.moveToLineEnd(extend: shift));
    final page = max(1, (_size.height / _lineHeight).floor() - 2);
    if (key == LogicalKeyboardKey.pageUp && !ctrl) return _handled(() => c.moveVertical(-1, extend: shift, count: page));
    if (key == LogicalKeyboardKey.pageDown && !ctrl) return _handled(() => c.moveVertical(1, extend: shift, count: page));

    if (ctrl) {
      if (key == LogicalKeyboardKey.keyA) return _handled(c.selectAll);
      if (key == LogicalKeyboardKey.keyC) return _handled(() => unawaited(c.copy()));
      if (key == LogicalKeyboardKey.keyF && !shift) return _handled(_find.findMode);
      if (key == LogicalKeyboardKey.keyL) return _handled(() => c.selectLine(c.selection.extentIndex));
      if (edit) {
        if (key == LogicalKeyboardKey.keyH) return _handled(_find.replaceMode);
        if (key == LogicalKeyboardKey.keyX) return _handled(() => unawaited(c.cut()));
        if (key == LogicalKeyboardKey.keyV) return _handled(() => unawaited(c.paste()));
        if (key == LogicalKeyboardKey.keyZ) return _handled(shift ? c.redo : c.undo);
        if (key == LogicalKeyboardKey.keyY) return _handled(c.redo);
        if (key == LogicalKeyboardKey.keyK && shift) return _handled(c.deleteSelectionLines);
        if (key == LogicalKeyboardKey.slash && widget.lineComment != null) return _handled(() => c.toggleLineComment(widget.lineComment!));
        if (key == LogicalKeyboardKey.backspace) return _handled(c.deleteWordBackward);
        if (key == LogicalKeyboardKey.delete) return _handled(c.deleteWordForward);
      }
      return KeyEventResult.ignored;
    }
    if (!edit) return KeyEventResult.ignored;
    if (shift && alt && key == LogicalKeyboardKey.keyA) return _handled(c.toggleBlockComment);
    if (key == LogicalKeyboardKey.backspace) return _handled(c.deleteBackward);
    if (key == LogicalKeyboardKey.delete) return _handled(c.deleteForward);
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return _handled(c.applyNewLine);
    if (key == LogicalKeyboardKey.tab) return _handled(shift ? c.applyOutdent : c.applyIndent);
    return KeyEventResult.ignored;
  }

  // ------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final showFind = _find.value != null && widget.findBuilder != null;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showFind) widget.findBuilder!(context, _find, widget.readOnly),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.indicatorBuilder != null) widget.indicatorBuilder!(context, _ctrl, _chunks, _indicator),
                Expanded(
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(onInvoke: (_) { _ctrl.selectAll(); return null; }),
                      CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(onInvoke: (intent) {
                        if (!intent.collapseSelection) {
                          unawaited(_ctrl.copy());
                        } else if (!widget.readOnly) {
                          unawaited(_ctrl.cut());
                        }
                        return null;
                      }),
                      PasteTextIntent: CallbackAction<PasteTextIntent>(onInvoke: (_) { if (!widget.readOnly) unawaited(_ctrl.paste()); return null; }),
                      UndoTextIntent: CallbackAction<UndoTextIntent>(onInvoke: (_) { if (!widget.readOnly) _ctrl.undo(); return null; }),
                      RedoTextIntent: CallbackAction<RedoTextIntent>(onInvoke: (_) { if (!widget.readOnly) _ctrl.redo(); return null; }),
                    },
                    child: Focus(
                      focusNode: _focus,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.text,
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _onPointerDown,
                          onPointerMove: _onPointerMove,
                          onPointerUp: _onPointerUp,
                          onPointerCancel: _onPointerUp,
                          onPointerSignal: _onPointerSignal,
                          child: _CodeField(state: this),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void performSelector(String selectorName) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}
}

class _CodeField extends LeafRenderObjectWidget {
  const _CodeField({required this.state});

  final _CodeEditorState state;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCode(state);

  @override
  void updateRenderObject(BuildContext context, _RenderCode renderObject) {
    renderObject.state = state;
  }
}

class _RenderCode extends RenderBox {
  _RenderCode(this.state);

  _CodeEditorState state;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    state._render = this;
  }

  @override
  void detach() {
    if (identical(state._render, this)) state._render = null;
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performLayout() => state.layoutCode(size);

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) => state.paintCode(context.canvas, offset, size);
}

/// Line numbers for the gutter.
class DefaultCodeLineNumber extends StatelessWidget {
  const DefaultCodeLineNumber({super.key, required this.controller, required this.notifier, required this.textStyle, required this.focusedTextStyle});

  final CodeLineEditingController controller;
  final CodeIndicatorValueNotifier notifier;
  final TextStyle textStyle, focusedTextStyle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (_, _) {
      final digits = max(3, '${controller.lineCount}'.length);
      final sample = TextPainter(text: TextSpan(text: '0' * digits, style: textStyle), textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling)..layout();
      final width = sample.width + 10;
      sample.dispose();
      return SizedBox(
        width: width,
        child: CustomPaint(painter: _LineNumberPainter(notifier, textStyle, focusedTextStyle)),
      );
    },
  );
}

class _LineNumberPainter extends CustomPainter {
  _LineNumberPainter(this.notifier, this.style, this.focused) : super(repaint: notifier);

  final CodeIndicatorValueNotifier notifier;
  final TextStyle style, focused;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final value = notifier.value;
    if (value == null) return;
    for (final para in value.paragraphs) {
      final number = TextPainter(
        text: TextSpan(text: '${para.index + 1}', style: para.index == value.focusedIndex ? focused : style),
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      )..layout();
      number.paint(canvas, Offset(size.width - number.width - 4, para.offset.dy + (para.preferredLineHeight - number.height) / 2));
      number.dispose();
    }
  }

  @override
  bool shouldRepaint(_LineNumberPainter old) => old.style != style || old.focused != focused;
}

/// The fold arrows.
class DefaultCodeChunkIndicator extends StatelessWidget {
  const DefaultCodeChunkIndicator({super.key, required this.width, required this.controller, required this.editing, required this.notifier, required this.color});

  final double width;
  final CodeChunkController controller;
  final CodeLineEditingController editing;
  final CodeIndicatorValueNotifier notifier;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        for (final para in notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
          if (d.localPosition.dy < para.offset.dy || d.localPosition.dy >= para.offset.dy + para.height) continue;
          if (editing.foldedRanges.containsKey(para.index)) {
            editing.expandChunk(para.index);
          } else {
            final chunk = controller.value.where((c) => c.index == para.index).firstOrNull;
            if (chunk != null) editing.collapseChunk(chunk.index, chunk.end);
          }
          return;
        }
      },
      child: CustomPaint(painter: _ChunkPainter(notifier, controller, editing, color)),
    ),
  );
}

class _ChunkPainter extends CustomPainter {
  _ChunkPainter(this.notifier, this.chunks, this.editing, this.color) : super(repaint: Listenable.merge([notifier, chunks]));

  final CodeIndicatorValueNotifier notifier;
  final CodeChunkController chunks;
  final CodeLineEditingController editing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final foldable = {for (final c in chunks.value) c.index};
    final paint = Paint()..color = color;
    for (final para in notifier.value?.paragraphs ?? const <CodeLineRenderParagraph>[]) {
      final folded = editing.foldedRanges.containsKey(para.index);
      if (!folded && !foldable.contains(para.index)) continue;
      final x = size.width / 2, y = para.offset.dy + para.preferredLineHeight / 2;
      final path = folded
          ? (Path()
              ..moveTo(x - 2.5, y - 4)
              ..lineTo(x + 2.5, y)
              ..lineTo(x - 2.5, y + 4)
              ..close())
          : (Path()
              ..moveTo(x - 4, y - 2.5)
              ..lineTo(x + 4, y - 2.5)
              ..lineTo(x, y + 2.5)
              ..close());
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_ChunkPainter old) => old.color != color;
}
