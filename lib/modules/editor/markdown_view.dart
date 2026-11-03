import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/theme.dart';
import 'engine/syntax.dart';
import 'svg_view.dart';
import '../../extensions/work/work_service.dart' show openUrl;
import '../../core/mono_font.dart';

enum MdKind { paragraph, heading, code, bullet, rule, quote, table, images }

class MdBlock {
  const MdBlock(this.kind, [this.text = '', this.level = 0, this.marker = '•', this.rows = const [], this.images = const []]);

  final MdKind kind;
  final String text;

  /// A heading's level, a list item's indent.
  final int level;

  /// How a list item starts, or a code block's language.
  final String marker;
  final List<List<String>> rows;
  final List<MdImage> images;
}

class MdImage {
  const MdImage(this.alt, this.url);

  final String alt, url;
}

final _imageLine = RegExp(r'^(?:\[?!\[[^\]]*\]\([^)\s]+[^)]*\)\]?(?:\([^)\s]+\))?\s*)+$');
final _image = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)');
final _htmlImage = RegExp(r'''<img\b[^>]*?\bsrc=["']([^"']+)["'][^>]*>''', caseSensitive: false);
final _tagsOnly = RegExp(r'^(?:</?[a-zA-Z][^>]*>\s*)+$');
final _tableRule = RegExp(r'^\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?$');

List<String> _tableCells(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  return [for (final cell in text.split(RegExp(r'(?<!\\)\|'))) cell.trim().replaceAll(r'\|', '|')];
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
      final language = trimmed.substring(3).trim();
      final code = <String>[];
      for (i++; i < lines.length && !lines[i].trimLeft().startsWith('```'); i++) {
        code.add(lines[i].trimRight());
      }
      blocks.add(MdBlock(MdKind.code, code.join('\n'), 0, language));
    } else if (trimmed.isEmpty) {
      flush();
    } else if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flush();
      blocks.add(const MdBlock(MdKind.rule));
    } else if (RegExp(r'^#{1,6} ').hasMatch(trimmed)) {
      flush();
      blocks.add(MdBlock(MdKind.heading, trimmed.replaceFirst(RegExp(r'^#+ '), ''), trimmed.indexOf(' ')));
    } else if (RegExp(r'^([*+-]|\d+\.) ').hasMatch(trimmed)) {
      flush();
      final start = RegExp(r'^([*+-]|\d+\.) ').firstMatch(trimmed)![1]!;
      var text = trimmed.substring(start.length + 1);
      var marker = start.endsWith('.') ? start : '•';
      if (RegExp(r'^\[[ xX]\] ').hasMatch(text)) {
        marker = text[1] == ' ' ? '☐' : '☑';
        text = text.substring(4);
      }
      blocks.add(MdBlock(MdKind.bullet, text, (line.length - trimmed.length) ~/ 2, marker));
    } else if (trimmed.startsWith('>')) {
      flush();
      final quote = <String>[];
      for (; i < lines.length && lines[i].trimLeft().startsWith('>'); i++) {
        quote.add(lines[i].trimLeft().substring(1).trim());
      }
      i--;
      blocks.add(MdBlock(MdKind.quote, quote.join(' ')));
    } else if (trimmed.contains('|') && i + 1 < lines.length && lines[i + 1].contains('-') && _tableRule.hasMatch(lines[i + 1].trim())) {
      flush();
      final rows = [_tableCells(trimmed)];
      for (i += 2; i < lines.length && lines[i].contains('|') && lines[i].trim().isNotEmpty; i++) {
        rows.add(_tableCells(lines[i]));
      }
      i--;
      blocks.add(MdBlock(MdKind.table, '', 0, '', rows));
    } else if (_imageLine.hasMatch(trimmed)) {
      flush();
      blocks.add(MdBlock(MdKind.images, '', 0, '', const [], [for (final m in _image.allMatches(trimmed)) MdImage(m[1]!, m[2]!)]));
    } else if (_tagsOnly.hasMatch(trimmed)) {
      flush();
      final html = _htmlImage.allMatches(trimmed);
      if (html.isNotEmpty) blocks.add(MdBlock(MdKind.images, '', 0, '', const [], [for (final m in html) MdImage('', m[1]!)]));
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
  const MarkdownView(this.source, {super.key, this.document = false, this.baseDir});

  final String source;

  /// A whole file rather than a tooltip: larger, with its headings at their sizes and its images drawn.
  final bool document;
  final String? baseDir;

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

  Widget _picture(MdImage image, ColorScheme scheme) {
    Widget missing() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(4)),
      child: Text(image.alt.isEmpty ? p.basename(image.url) : image.alt, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    );
    final url = image.url;
    final remote = url.startsWith('http://') || url.startsWith('https://');
    if (!widget.document || url.isEmpty) return missing();
    if (remote) {
      // Flutter can't decode SVG, and that's what most README badges are.
      if (p.extension(Uri.tryParse(url)?.path ?? '').toLowerCase() == '.svg' || url.contains('shields.io')) return missing();
      return Image.network(url, errorBuilder: (_, _, _) => missing());
    }
    final path = p.normalize(p.join(widget.baseDir ?? '', Uri.decodeFull(url)));
    if (p.extension(path).toLowerCase() == '.svg') {
      try {
        final svg = parseSvg(File(path).readAsStringSync());
        return svg == null ? missing() : SizedBox(height: 120, child: SvgView(svg));
      } on Exception {
        return missing();
      }
    }
    return Image.file(File(path), errorBuilder: (_, _, _) => missing());
  }

  Widget _code(String code, ThemeData theme, {String language = ''}) {
    const base = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, height: 1.35);
    return Text.rich(highlightSnippet(code, language.isEmpty ? '.dart' : '.$language', appTheme.value.syntax, base.copyWith(color: theme.colorScheme.onSurface)));
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
    final body = TextStyle(fontSize: widget.document ? 14 : 13, height: widget.document ? 1.55 : 1.4);
    const headings = [26.0, 21.0, 17.0, 15.0, 14.0, 13.0];
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
                child: _code(b.text, theme, language: b.marker == '•' ? '' : b.marker),
              ),
              MdKind.heading when widget.document => Padding(
                padding: EdgeInsets.only(top: b.level < 3 ? 20 : 14, bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text.rich(inline(b.text), style: TextStyle(fontSize: headings[(b.level - 1).clamp(0, 5)], height: 1.3, fontWeight: FontWeight.w700)),
                    if (b.level < 3) const Divider(height: 10),
                  ],
                ),
              ),
              MdKind.heading => Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 2),
                child: Text.rich(inline(b.text), style: body.copyWith(fontWeight: FontWeight.w700)),
              ),
              MdKind.quote => Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                decoration: BoxDecoration(border: Border(left: BorderSide(color: scheme.outlineVariant, width: 3))),
                child: Text.rich(inline(b.text), style: body.copyWith(color: scheme.onSurfaceVariant)),
              ),
              MdKind.table => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Table(
                    defaultColumnWidth: const IntrinsicColumnWidth(),
                    border: TableBorder.all(color: scheme.outlineVariant),
                    children: [
                      for (final (y, row) in b.rows.indexed)
                        TableRow(
                          decoration: y == 0 ? BoxDecoration(color: scheme.surfaceContainerLow) : null,
                          children: [
                            for (var x = 0; x < b.rows.fold<int>(0, (most, r) => max(most, r.length)); x++)
                              Container(
                                constraints: const BoxConstraints(maxWidth: 420),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                child: Text.rich(inline(x < row.length ? row[x] : ''), style: y == 0 ? body.copyWith(fontWeight: FontWeight.w700) : body),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              MdKind.images => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Wrap(spacing: 6, runSpacing: 6, children: [for (final i in b.images) _picture(i, scheme)]),
              ),
              MdKind.bullet => Padding(
                padding: EdgeInsets.only(top: 2, left: 4.0 + b.level * 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (b.marker == '☑' || b.marker == '☐')
                      Padding(
                        padding: const EdgeInsets.only(top: 3, right: 6),
                        child: Icon(b.marker == '☑' ? Icons.check_box : Icons.check_box_outline_blank, size: 15, color: scheme.primary),
                      )
                    else
                      Text('${b.marker}  ', style: body),
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
