import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../core/files.dart';
import '../../../../core/source_links.dart';
import '../../services/device_adb.dart';
import '../../services/logcat_controller.dart';
import '../../../../core/mono_font.dart';
import '../../../../core/platform_keys.dart';

const _levels = ['V', 'D', 'I', 'W', 'E'];

class LogcatTab extends StatefulWidget {
  const LogcatTab({super.key, required this.log, required this.deviceName, required this.focus});

  final LogcatController log;
  final String deviceName;
  final ValueNotifier<String?> focus;

  @override
  State<LogcatTab> createState() => _LogcatTabState();
}

class _LogcatTabState extends State<LogcatTab> {
  final _scroll = ScrollController();
  final _queryCtl = TextEditingController();
  var _onlyOurs = true;
  var _autoScroll = true;
  var _minLevel = 'V';
  var _query = '';

  LogcatController get log => widget.log;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_refresh);
    log.addListener(_onLog);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_refresh);
    log.removeListener(_onLog);
    _scroll.dispose();
    _queryCtl.dispose();
    super.dispose();
  }

  void _refresh() => setState(() {});

  void _onLog() {
    if (!mounted) return;
    setState(() {});
    if (_autoScroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  List<LogLine> get _visible {
    final minIdx = _levels.indexOf(_minLevel);
    final q = _query.toLowerCase();
    final focus = widget.focus.value;
    return log.lines.where((l) {
      if (_onlyOurs) {
        final app = log.ourPids[l.pid];
        if (app == null || (focus != null && app != focus)) return false;
      }
      if (!l.crash && _levels.indexOf(l.level) < minIdx) return false;
      return q.isEmpty || l.raw.toLowerCase().contains(q);
    }).toList();
  }

  void _jumpToCrash(List<LogLine> visible) {
    final i = visible.lastIndexWhere((l) => l.crash);
    if (i < 0) {
      // Crash exists but is filtered out; clear all filters so it shows.
      setState(() {
        _onlyOurs = false;
        _minLevel = 'V';
        _query = '';
        _queryCtl.clear();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCrash(_visible));
      return;
    }
    setState(() => _autoScroll = false);
    _scroll.jumpTo((i * 18.0).clamp(0, _scroll.position.maxScrollExtent));
  }

  Future<void> _save(List<LogLine> visible) async {
    final dir = await outputDir();
    final file = File(
      '${dir.path}${Platform.pathSeparator}logcat_${safeFileName(widget.deviceName)}_${timestamp()}.txt',
    );
    await file.writeAsString(visible.map((l) => l.raw).join('\n'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Log saved: ${file.path}'),
        behavior: SnackBarBehavior.floating,
        width: 520,
        action: SnackBarAction(label: 'Open folder', onPressed: () => revealInExplorer(file.path)),
      ),
    );
  }

  Color? _color(LogLine l, ColorScheme scheme) {
    if (l.crash) return Colors.red;
    return switch (l.level) {
      'E' || 'F' => Colors.red.shade400,
      'W' => Colors.orange.shade600,
      'I' => scheme.onSurface,
      'D' => Colors.blueGrey.shade400,
      _ => scheme.outline,
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = _visible;
    final focus = widget.focus.value;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _queryCtl,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Filter text / tag…',
                    prefixIcon: Icon(Icons.filter_list),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [for (final l in _levels) ButtonSegment(value: l, label: Text(l))],
                selected: {_minLevel},
                onSelectionChanged: (s) => setState(() => _minLevel = s.first),
              ),
              FilterChip(
                label: Text(focus == null ? 'My apps only' : '${appShort(focus)} only'),
                tooltip: 'Change app via the app picker above',
                selected: _onlyOurs,
                onSelected: (v) => setState(() => _onlyOurs = v),
              ),
              FilterChip(
                label: const Text('Auto-scroll'),
                selected: _autoScroll,
                onSelected: (v) => setState(() => _autoScroll = v),
              ),
              IconButton(
                tooltip: log.paused ? 'Resume' : 'Pause',
                onPressed: log.togglePause,
                icon: Icon(log.paused ? Icons.play_arrow : Icons.pause),
              ),
              IconButton(
                tooltip: platformKeys('Clear (Ctrl+L)'),
                onPressed: log.clear,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              IconButton(tooltip: 'Save to file', onPressed: () => _save(lines), icon: const Icon(Icons.save_alt)),
              IconButton(tooltip: 'Restart logcat', onPressed: log.restart, icon: const Icon(Icons.restart_alt)),
              Text('${lines.length} lines', style: TextStyle(color: scheme.outline)),
            ],
          ),
        ),
        if (log.crashes.isNotEmpty)
          MaterialBanner(
            backgroundColor: Colors.red.withValues(alpha: 0.12),
            leading: const Icon(Icons.bug_report, color: Colors.red),
            content: Text(
              '${log.crashes.length} crash(es) detected · last ${log.crashes.last.time ?? ''}: '
              '${log.crashes.last.message}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              TextButton(onPressed: () => _jumpToCrash(lines), child: const Text('View')),
              TextButton(onPressed: log.clearCrashes, child: const Text('Dismiss')),
            ],
          ),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: scheme.surfaceContainerLowest,
            child: lines.isEmpty
                ? _Empty(
                    onlyOurs: _onlyOurs,
                    anyRunning: log.ourPids.isNotEmpty,
                    focus: focus,
                    onShowAll: () => setState(() => _onlyOurs = false),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: lines.length,
                      itemExtent: 18,
                      itemBuilder: (_, i) {
                        final l = lines[i];
                        final app = log.ourPids[l.pid];
                        final prefix = app == null ? '' : '[${appShort(app)}] ';
                        return Container(
                          color: l.crash ? Colors.red.withValues(alpha: 0.15) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: SourceLinkText(
                            l.time == null ? l.raw : '${l.time}  ${l.level}  $prefix${l.tag}: ${l.message}',
                            appId: app,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: _color(l, scheme)),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onlyOurs, required this.anyRunning, required this.focus, required this.onShowAll});

  final bool onlyOurs;
  final bool anyRunning;
  final String? focus;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reason = !onlyOurs
        ? 'No logs match the filter yet.'
        : focus != null
        ? '${appName(focus!)} is not running on this device.'
        : anyRunning
        ? 'No logs from your apps match the filter yet.'
        : 'None of your apps are running on this device.';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.subject, size: 40, color: scheme.outline),
          const SizedBox(height: 8),
          Text(reason),
          if (onlyOurs) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onShowAll, child: const Text('Show all device logs')),
          ],
        ],
      ),
    );
  }
}
