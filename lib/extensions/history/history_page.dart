import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/files.dart';
import '../../core/history.dart';
import '../../core/mono_font.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  var _tab = 0;
  final _search = TextEditingController();
  List<HistoryEntry> _activity = const [];
  List<HistoryEntry> _crashes = const [];
  List<File> _logs = const [];
  String? _logKind;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _load();
    // Other windows (workspaces) append too; refresh while the page is visible.
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) _load();
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final activity = await History.read('activity');
    final crashes = await History.read('crashes');
    final logs = (await History.sessionsDir()).listSync(recursive: true).whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (!mounted) return;
    setState(() {
      _activity = activity;
      _crashes = crashes;
      _logs = logs;
    });
  }

  bool _match(String haystack) {
    final q = _search.text.trim().toLowerCase();
    return q.isEmpty || q.split(RegExp(r'\s+')).every(haystack.toLowerCase().contains);
  }

  bool _entryMatch(HistoryEntry e) => _match('${e.kind} ${e.title} ${e.data.values.join(' ')}');

  static String _kindOf(File f) => f.parent.uri.pathSegments.where((s) => s.isNotEmpty).last;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final activity = _activity.where(_entryMatch).toList();
    final crashes = _crashes.where(_entryMatch).toList();
    final logs = _logs
        .where((f) => _logKind == null || _kindOf(f) == _logKind)
        .where((f) => _match(f.uri.pathSegments.last))
        .toList();
    final logKinds = {for (final f in _logs) _kindOf(f)}.toList()..sort();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('History', style: text.headlineSmall),
                  Text(
                    'Kept on this PC for ${History.retention.inDays} days, from every Slipway window',
                    style: text.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: 300,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: 'Search device, app, file…',
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              IconButton(
                tooltip: 'Open history folder',
                onPressed: () async => revealInExplorer((await History.dir()).path),
                icon: const Icon(Icons.folder_open_outlined),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 0,
                icon: const Icon(Icons.timeline, size: 18),
                label: Text('Activity (${activity.length})'),
              ),
              ButtonSegment(
                value: 1,
                icon: const Icon(Icons.bug_report_outlined, size: 18),
                label: Text('Crashes (${crashes.length})'),
              ),
              ButtonSegment(
                value: 2,
                icon: const Icon(Icons.article_outlined, size: 18),
                label: Text('Logs (${logs.length})'),
              ),
            ],
            selected: {_tab},
            onSelectionChanged: (v) => setState(() => _tab = v.first),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: switch (_tab) {
                0 => _EntryList(entries: activity, empty: 'No activity yet'),
                1 => _EntryList(entries: crashes, empty: 'No crashes recorded 🎉', crash: true),
                _ => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(10),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          ChoiceChip(
                            label: const Text('All'),
                            selected: _logKind == null,
                            onSelected: (_) => setState(() => _logKind = null),
                          ),
                          for (final k in logKinds)
                            ChoiceChip(
                              label: Text(k),
                              selected: _logKind == k,
                              onSelected: (_) => setState(() => _logKind = k),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(child: _LogList(files: logs)),
                  ],
                ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _when(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final d = today.difference(day).inDays;
  final date = d == 0 ? 'Today' : (d == 1 ? 'Yesterday' : '${t.year}-${two(t.month)}-${two(t.day)}');
  return '$date ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

IconData _iconFor(String kind) => switch (kind) {
  'crash' => Icons.bug_report_outlined,
  'device' => Icons.phone_android,
  'flutter' => Icons.bolt_outlined,
  'task' => Icons.download_done,
  'screenshot' => Icons.photo_camera_outlined,
  'bugreport' => Icons.assignment_outlined,
  'maintenance' => Icons.cleaning_services_outlined,
  'emulator' => Icons.devices_other,
  'network' => Icons.shield_outlined,
  _ => Icons.circle_outlined,
};

class _EntryList extends StatelessWidget {
  const _EntryList({required this.entries, required this.empty, this.crash = false});

  final List<HistoryEntry> entries;
  final String empty;
  final bool crash;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return Center(
        child: Text(empty, style: TextStyle(color: scheme.outline)),
      );
    }
    return ListView.separated(
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = entries[i];
        final details = {
          for (final d in e.data.entries)
            if (d.key != 'log') d.key: '${d.value}',
        };
        final log = e.data['log'] as String?;
        return ExpansionTile(
          leading: Icon(_iconFor(e.kind), color: crash ? scheme.error : scheme.primary, size: 20),
          title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${_when(e.time)}${details['device'] != null ? ' · ${details['device']}' : ''}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final d in details.entries) _Detail(name: d.key, value: d.value),
            if (log != null) ...[
              const SizedBox(height: 8),
              if (!crash && File(log).existsSync())
                _Detail(name: 'log', value: log)
              else ...[
                Row(
                  children: [
                    Text(
                      'Log',
                      style: TextStyle(fontWeight: FontWeight.w600, color: scheme.outline),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(ClipboardData(text: log)),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy'),
                    ),
                  ],
                ),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 320),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: const Color(0xFF0F1115), borderRadius: BorderRadius.circular(8)),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      log,
                      style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 11.5, color: Colors.white70),
                    ),
                  ),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPath = value.contains(r':\') && (File(value).existsSync() || Directory(value).existsSync());
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(name, style: TextStyle(color: scheme.outline, fontSize: 12.5)),
          ),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 12.5))),
          if (isPath)
            TextButton(
              onPressed: () => revealInExplorer(value),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: const Text('Show'),
            ),
        ],
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.files});

  final List<File> files;

  static String _size(int b) =>
      b > 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / 1024).toStringAsFixed(0)} KB';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (files.isEmpty) {
      return Center(
        child: Text('No session logs yet', style: TextStyle(color: scheme.outline)),
      );
    }
    return ListView.separated(
      itemCount: files.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final f = files[i];
        final kind = f.parent.uri.pathSegments.where((s) => s.isNotEmpty).last;
        return ListTile(
          leading: Icon(
            switch (kind) {
              'logcat' => Icons.receipt_long_outlined,
              'flutter' => Icons.bolt_outlined,
              _ => Icons.terminal,
            },
            color: scheme.primary,
            size: 20,
          ),
          title: Text(f.uri.pathSegments.last, style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 13)),
          subtitle: Text(
            '$kind · ${_when(f.lastModifiedSync())} · ${_size(f.lengthSync())}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          trailing: Wrap(
            spacing: 4,
            children: [
              TextButton(onPressed: () => openExternal(f.path), child: const Text('Open')),
              TextButton(onPressed: () => revealInExplorer(f.path), child: const Text('Show')),
            ],
          ),
        );
      },
    );
  }
}
