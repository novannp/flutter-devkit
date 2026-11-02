import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' show ExceptionPauseMode;

import 'debugger.dart';
import '../../core/compact_dropdown.dart';
import '../../core/mono_font.dart';

class DebugPanel extends StatefulWidget {
  const DebugPanel({super.key, required this.debugger, required this.root, required this.onOpen});

  final Debugger debugger;
  final String root;
  final void Function(String path, int line, int column) onOpen;

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  final _expression = TextEditingController();
  String? _result;

  @override
  void dispose() {
    _expression.dispose();
    super.dispose();
  }

  Future<void> _evaluate(String text) async {
    if (text.trim().isEmpty) return;
    final result = await widget.debugger.evaluate(text.trim());
    if (mounted) setState(() => _result = result);
  }

  String _shortPath(String path) => p.isWithin(widget.root, path) ? p.relative(path, from: widget.root) : p.basename(path);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.debugger,
      builder: (_, _) {
        final d = widget.debugger;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _controls(d, scheme),
            const Divider(height: 1),
            Expanded(flex: 4, child: _section('Variables', scheme, _variables(d, scheme))),
            const Divider(height: 1),
            Expanded(flex: 3, child: _section('Call stack', scheme, d.frames.isEmpty ? _empty(d, scheme) : _stack(d, scheme))),
            const Divider(height: 1),
            Expanded(flex: 2, child: _section('Breakpoints', scheme, _breakpoints(d, scheme))),
          ],
        );
      },
    );
  }

  Widget _controls(Debugger d, ColorScheme scheme) {
    Widget button(String tip, IconData icon, VoidCallback? onPressed) => IconButton(
      tooltip: tip,
      iconSize: 17,
      onPressed: onPressed,
      icon: Icon(icon),
    );
    final running = d.connected && !d.paused;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (d.paused)
                button('Continue (F5)', Icons.play_arrow, d.resume)
              else
                button('Pause (F6)', Icons.pause, running ? d.pause : null),
              button('Step over (F10)', Icons.redo, d.paused ? d.stepOver : null),
              button('Step into (F11)', Icons.south_east, d.paused ? d.stepInto : null),
              button('Step out (Shift+F11)', Icons.north_east, d.paused ? d.stepOut : null),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  switch (d.state) {
                    DebugState.paused => d.pauseReason,
                    DebugState.running => 'Running',
                    DebugState.disconnected => 'Not running',
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: d.paused ? const Color(0xFFF59E0B) : scheme.outline),
                ),
              ),
            ],
          ),
          CompactDropdown<String>(
            value: d.exceptionMode,
            isDense: true,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            style: TextStyle(fontSize: 12, color: scheme.onSurface),
            onChanged: (v) => d.setExceptionMode(v!),
            items: const [
              DropdownMenuItem(value: ExceptionPauseMode.kUnhandled, child: Text('Pause on uncaught exceptions')),
              DropdownMenuItem(value: ExceptionPauseMode.kAll, child: Text('Pause on all exceptions')),
              DropdownMenuItem(value: ExceptionPauseMode.kNone, child: Text('Ignore exceptions')),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _expression,
            enabled: d.paused,
            onSubmitted: _evaluate,
            style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5),
            decoration: const InputDecoration(hintText: 'Evaluate in this frame', contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Tooltip(
                message: _result!,
                child: Text(
                  '= $_result',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: scheme.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _section(String title, ColorScheme scheme, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
        child: Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.outline)),
      ),
      Expanded(child: child),
    ],
  );

  Widget _empty(Debugger d, ColorScheme scheme) => Padding(
    padding: const EdgeInsets.all(10),
    child: Text(
      d.connected ? 'The stack shows up when the app pauses.' : 'Press F5 to run. Click the gutter or press F9 for a breakpoint.',
      style: TextStyle(fontSize: 12.5, color: scheme.outline),
    ),
  );

  Widget _stack(Debugger d, ColorScheme scheme) => ListView.builder(
    itemCount: d.frames.length,
    itemExtent: 22,
    itemBuilder: (_, i) {
      final f = d.frames[i];
      final path = f.path;
      return InkWell(
        onTap: () {
          d.selectFrame(i);
          if (path != null) widget.onOpen(path, f.line, f.column);
        },
        child: Container(
          color: i == d.selectedFrame ? scheme.primary.withValues(alpha: .12) : null,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Flexible(
                child: Text(
                  f.function,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: path == null ? scheme.outline : scheme.onSurface),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${path == null ? f.uri : _shortPath(path)}:${f.line + 1}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _variables(Debugger d, ColorScheme scheme) => ListView(
    children: [for (final v in d.variables) _VariableRow(key: ValueKey(v), variable: v, debugger: d, depth: 0)],
  );

  Widget _breakpoints(Debugger d, ColorScheme scheme) {
    final all = [
      for (final e in d.breakpoints.entries)
        for (final line in e.value.toList()..sort()) (e.key, line),
    ];
    return ListView.builder(
      itemCount: all.length,
      itemExtent: 22,
      itemBuilder: (_, i) {
        final (path, line) = all[i];
        return InkWell(
          onTap: () => widget.onOpen(path, line, 0),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 10, color: breakpointColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${_shortPath(path)}:${line + 1}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
                ),
                IconButton(
                  tooltip: 'Remove',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  onPressed: () => d.toggleBreakpoint(path, line),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

const breakpointColor = Color(0xFFEF4444);

class _VariableRow extends StatefulWidget {
  const _VariableRow({super.key, required this.variable, required this.debugger, required this.depth});

  final DebugVariable variable;
  final Debugger debugger;
  final int depth;

  @override
  State<_VariableRow> createState() => _VariableRowState();
}

class _VariableRowState extends State<_VariableRow> {
  List<DebugVariable>? _children;
  var _open = false;

  Future<void> _toggle() async {
    if (!widget.variable.expandable) return;
    final opening = !_open;
    setState(() => _open = opening);
    if (opening && _children == null) {
      final loaded = await widget.debugger.children(widget.variable);
      if (mounted) setState(() => _children = loaded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = widget.variable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggle,
          child: Padding(
            padding: EdgeInsets.only(left: 6.0 + widget.depth * 14, right: 10, top: 3, bottom: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: v.expandable ? Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 15, color: scheme.outline) : null,
                ),
                Flexible(
                  child: Text(
                    '${v.name}: ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: scheme.primary),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(v.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ),
        if (_open)
          for (final c in _children ?? const <DebugVariable>[])
            _VariableRow(key: ValueKey(c), variable: c, debugger: widget.debugger, depth: widget.depth + 1),
      ],
    );
  }
}
