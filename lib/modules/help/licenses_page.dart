import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/licenses.dart';
import '../../extensions/work/work_service.dart' show openUrl;

Future<void> showLicenses(BuildContext context) => showDialog<void>(context: context, builder: (_) => const LicensesDialog());

class _Row {
  const _Row(this.group, this.title, {this.by, this.license, this.url, this.asset, this.text});

  final String group, title;
  final String? by, license, url, asset, text;

  bool matches(String q) => [title, by ?? '', license ?? ''].any((v) => v.toLowerCase().contains(q));
}

const _own = 'Slipway';
const _shipped = 'Ships with the app';
const _installed = 'Runs what you installed';
const _packages = 'Dart packages';

_Row _creditRow(String group, Credit c) => _Row(group, c.name, by: c.by, license: c.license, url: c.url, asset: c.asset);

final _fixedRows = [
  const _Row(_own, 'Slipway', by: 'Novan Noviansyah Pratama and contributors', license: 'MIT', asset: 'LICENSE'),
  const _Row(_own, 'Third-party notices', asset: 'THIRD_PARTY_NOTICES.md'),
  for (final c in shippedCredits) _creditRow(_shipped, c),
  for (final c in installedCredits) _creditRow(_installed, c),
];

/// Everything Slipway ships, runs or is built with, and whose work it is.
class LicensesDialog extends StatefulWidget {
  const LicensesDialog({super.key});

  @override
  State<LicensesDialog> createState() => _LicensesDialogState();
}

class _LicensesDialogState extends State<LicensesDialog> {
  var _rows = _fixedRows;
  late _Row _picked = _fixedRows.first;
  var _query = '';
  String? _text;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPackages());
    unawaited(_loadText());
  }

  Future<void> _loadPackages() async {
    final bundled = {for (final (name, _) in bundledLicenses) name};
    final texts = <String, List<String>>{};
    await for (final entry in LicenseRegistry.licenses) {
      final text = entry.paragraphs.map((x) => '${'  ' * max(0, x.indent)}${x.text}').join('\n\n');
      for (final name in entry.packages) {
        if (!bundled.contains(name)) texts.putIfAbsent(name, () => []).add(text);
      }
    }
    final names = texts.keys.toList()..sort();
    if (!mounted) return;
    setState(() => _rows = [..._fixedRows, for (final n in names) _Row(_packages, n, text: texts[n]!.join('\n\n--------\n\n'))]);
  }

  Future<void> _loadText() async {
    final row = _picked;
    final asset = row.asset;
    final text = row.text ?? (asset == null ? null : await rootBundle.loadString(asset));
    if (mounted && identical(row, _picked)) setState(() => _text = text);
  }

  void _pick(_Row row) {
    setState(() {
      _picked = row;
      _text = null;
    });
    unawaited(_loadText());
  }

  Widget _list(ColorScheme scheme) {
    final q = _query.trim().toLowerCase();
    final shown = _rows.where((r) => q.isEmpty || r.matches(q)).toList();
    if (shown.isEmpty) return Center(child: Text('Nothing matches', style: TextStyle(color: scheme.outline)));
    final items = <Object>[];
    for (final (i, r) in shown.indexed) {
      if (i == 0 || shown[i - 1].group != r.group) items.add(r.group);
      items.add(r);
    }
    final count = _rows.where((r) => r.group == _packages).length;
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (_, i) {
        final item = items[i];
        if (item is String) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(item == _packages ? '$item ($count)' : item, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: scheme.outline)),
          );
        }
        final row = item as _Row;
        return InkWell(
          onTap: () => _pick(row),
          child: Container(
            color: identical(row, _picked) ? scheme.primary.withValues(alpha: .14) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                if (row.by != null) Text(row.by!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: scheme.outline)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _details(ColorScheme scheme) {
    final row = _picked;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(row.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        if (row.by != null) ...[const SizedBox(height: 2), Text('By ${row.by}', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))],
        if (row.license != null) ...[const SizedBox(height: 2), Text('License: ${row.license}', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))],
        if (row.url != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(onPressed: () => openUrl(row.url!), child: const Text('Open its page')),
            ),
          ),
        const SizedBox(height: 14),
        if (row.group == _installed)
          Text("Not part of Slipway. It starts the copy you installed, under that project's own license.", style: TextStyle(fontSize: 12.5, color: scheme.outline))
        else if (_text == null)
          const Align(alignment: Alignment.centerLeft, child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
        else
          SelectableText(_text!, style: const TextStyle(fontSize: 12, height: 1.35)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: min(860, size.width - 48),
        height: min(600, size.height - 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('Licenses', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  IconButton(tooltip: 'Close', icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: min(280, size.width / 3),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: TextField(
                            autofocus: true,
                            decoration: const InputDecoration(isDense: true, hintText: 'Search', prefixIcon: Icon(Icons.search, size: 16)),
                            style: const TextStyle(fontSize: 13),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                        Expanded(child: _list(scheme)),
                      ],
                    ),
                  ),
                  VerticalDivider(width: 1, color: scheme.outlineVariant),
                  Expanded(child: _details(scheme)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
