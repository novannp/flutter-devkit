import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'engine/syntax.dart';
import '../../extensions/work/work_service.dart' show openUrl;
import '../../core/mono_font.dart';

enum MdKind { paragraph, heading, code, bullet, rule }

class MdBlock {
  const MdBlock(this.kind, [this.text = '']);

  final MdKind kind;
  final String text;
}

/// The Markdown that dartdoc comments and the analysis server actually use, not all of CommonMark.
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(MdBlock(MdKind.paragraph, paragraph.join(' ')));
    paragraph.clear();
  }

  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      flush();
      final code = <String>[];
      for (i++; i < lines.length && !lines[i].trimLeft().startsWith('```'); i++) {
        code.add(lines[i].trimRight());
      }
      blocks.add(MdBlock(MdKind.code, code.join('\n')));
    } else if (trimmed.isEmpty) {
      flush();
    } else if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flush();
      blocks.add(const MdBlock(MdKind.rule));
    } else if (RegExp(r'^#{1,6} ').hasMatch(trimmed)) {
      flush();
      blocks.add(MdBlock(MdKind.heading, trimmed.replaceFirst(RegExp(r'^#+ '), '')));
    } else if (RegExp(r'^([*-]|\d+\.) ').hasMatch(trimmed)) {
      flush();
      blocks.add(MdBlock(MdKind.bullet, trimmed.replaceFirst(RegExp(r'^([*-]|\d+\.) '), '')));
    } else {
      paragraph.add(trimmed);
    }
  }
  flush();
  return blocks;
}

final _inline = RegExp(r'`([^`]+)`|\*\*(.+?)\*\*|\*([^*\s][^*]*?)\*|\[([^\]]+)\]\(([^)\s]+)\)|\[([\w.$]+)\]');

/// Builds the text of one block. [onLink] makes the recognizer, so the widget that owns it can dispose it.
TextSpan markdownInline(String text, {required Color accent, GestureRecognizer Function(String url)? onLink}) {
  final spans = <InlineSpan>[];
  var at = 0;
  const mono = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5);
  for (final m in _inline.allMatches(text)) {
    if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
    if (m[1] != null) {
      spans.add(TextSpan(text: m[1], style: mono.copyWith(color: accent)));
    } else if (m[2] != null) {
      spans.add(TextSpan(text: m[2], style: const TextStyle(fontWeight: FontWeight.w700)));
    } else if (m[3] != null) {
      spans.add(TextSpan(text: m[3], style: const TextStyle(fontStyle: FontStyle.italic)));
    } else if (m[4] != null) {
      spans.add(TextSpan(text: m[4], style: TextStyle(color: accent, decoration: TextDecoration.underline), recognizer: onLink?.call(m[5]!)));
    } else {
      // A dartdoc reference, like [State].
      spans.add(TextSpan(text: m[6], style: mono.copyWith(color: accent)));
    }
    at = m.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(children: spans);
}

class MarkdownView extends StatefulWidget {
  const MarkdownView(this.source, {super.key});

  final String source;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  final _links = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final l in _links) {
      l.dispose();
    }
    super.dispose();
  }

  GestureRecognizer _link(String url) {
    final recognizer = TapGestureRecognizer()..onTap = () => openUrl(url);
    _links.add(recognizer);
    return recognizer;
  }

  Widget _code(String code, ThemeData theme) {
    const base = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, height: 1.35);
    return Text.rich(highlightSnippet(code, '.dart', appTheme.value.syntax, base.copyWith(color: theme.colorScheme.onSurface)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    for (final l in _links) {
      l.dispose();
    }
    _links.clear();
    TextSpan inline(String text) => markdownInline(text, accent: scheme.primary, onLink: _link);
    const body = TextStyle(fontSize: 13, height: 1.4);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final b in parseMarkdown(widget.source))
            switch (b.kind) {
              MdKind.code => Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: scheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(6)),
                child: _code(b.text, theme),
              ),
              MdKind.heading => Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text.rich(inline(b.text), style: body.copyWith(fontWeight: FontWeight.w700)),
              ),
              MdKind.bullet => Padding(
                padding: const EdgeInsets.only(top: 2, left: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  ', style: body),
                    Expanded(child: Text.rich(inline(b.text), style: body)),
                  ],
                ),
              ),
              MdKind.rule => const Divider(height: 14),
              MdKind.paragraph => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text.rich(inline(b.text), style: body),
              ),
            },
        ],
      ),
    );
  }
}
