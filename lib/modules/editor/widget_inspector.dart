import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../../core/mono_font.dart';
import 'debugger.dart';
import 'editor_workspace.dart' show EditTarget;

const _group = 'devkit-inspector';
const _service = 'ext.flutter.inspector';

class InspectorNode {
  const InspectorNode(this.id, this.type, this.description, this.children, {this.path, this.line, this.column});

  factory InspectorNode.fromJson(Map<String, dynamic> json) {
    final location = json['creationLocation'] as Map?;
    final file = location?['file'] as String?;
    final description = json['description'] as String? ?? '';
    return InspectorNode(
      json['valueId'] as String?,
      json['widgetRuntimeType'] as String? ?? description,
      description,
      [for (final c in (json['children'] as List?) ?? const []) InspectorNode.fromJson((c as Map).cast<String, dynamic>())],
      path: file == null ? null : _pathOf(file),
      line: location?['line'] as int?,
      column: location?['column'] as int?,
    );
  }

  final String? id;
  final String type, description;
  final List<InspectorNode> children;
  final String? path;

  /// From 1, as the framework reports them.
  final int? line, column;

  static String? _pathOf(String file) {
    final uri = Uri.tryParse(file);
    return uri != null && uri.isScheme('file') ? uri.toFilePath() : null;
  }
}

/// The rows a tree shows, depth first, skipping what's under a collapsed node.
List<(InspectorNode, int)> flattenTree(InspectorNode? root, Set<String?> collapsed) {
  final rows = <(InspectorNode, int)>[];
  void visit(InspectorNode node, int depth) {
    rows.add((node, depth));
    if (collapsed.contains(node.id)) return;
    for (final c in node.children) {
      visit(c, depth + 1);
    }
  }

  if (root != null) visit(root, 0);
  return rows;
}

/// A running app's widget tree, read through the framework's inspector service extensions.
class WidgetTreeInspector extends ChangeNotifier {
  WidgetTreeInspector(this.debugger) {
    _wasConnected = debugger.connected;
    debugger.addListener(_onDebugger);
    debugger.onExtensionEvent = _onExtension;
  }

  final Debugger debugger;

  /// Opens the source of what was picked on the device.
  ValueChanged<EditTarget>? onNavigate;

  InspectorNode? root;
  InspectorNode? selected;
  List<(String, String)> properties = const [];
  final collapsed = <String?>{};
  var loading = false;
  var selectMode = false;
  var debugPaint = false;
  String? error;
  var _wasConnected = false;
  var _disposed = false;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _onDebugger() {
    if (debugger.connected == _wasConnected) return;
    _wasConnected = debugger.connected;
    root = selected = null;
    properties = const [];
    collapsed.clear();
    selectMode = debugPaint = false;
    error = null;
    _changed();
  }

  void _onExtension(vm.Event event) {
    if (event.extensionKind != 'navigate') return;
    final data = event.extensionData?.data ?? const {};
    if (data['source'] != 'flutter.inspector') return;
    final file = data['file'], line = data['line'], column = data['column'];
    if (file is String && line is int) {
      final path = Uri.tryParse(file)?.toFilePath();
      if (path != null) onNavigate?.call(EditTarget(path, line - 1, column is int ? column - 1 : 0));
    }
    unawaited(refresh());
  }

  Future<Map<String, dynamic>?> _tree() async {
    final newer = await debugger.callExtension('$_service.getRootWidgetTree', {
      'groupName': _group,
      'isSummaryTree': 'true',
      'withPreviews': 'false',
      'fullDetails': 'true',
    });
    final result = newer?['result'];
    if (result is Map) return result.cast<String, dynamic>();
    // Projects on an older Flutter only have this one.
    final older = await debugger.callExtension('$_service.getRootWidgetSummaryTree', {'objectGroup': _group});
    final legacy = older?['result'];
    return legacy is Map ? legacy.cast<String, dynamic>() : null;
  }

  Future<void> refresh() async {
    if (!debugger.connected) return;
    loading = true;
    error = null;
    _changed();
    await debugger.callExtension('$_service.disposeGroup', {'objectGroup': _group});
    final json = await _tree();
    loading = false;
    if (json == null) {
      root = selected = null;
      properties = const [];
      error = 'The widget tree is not available. It needs a Flutter app in debug mode.';
      return _changed();
    }
    root = InspectorNode.fromJson(json);
    selected = null;
    properties = const [];
    _changed();
    await _adoptDeviceSelection();
  }

  /// After a pick on the device, finds that widget in the fresh tree.
  Future<void> _adoptDeviceSelection() async {
    final picked = await debugger.callExtension('$_service.getSelectedSummaryWidget', {'objectGroup': _group});
    final result = picked?['result'];
    final id = result is Map ? result['valueId'] : null;
    if (id == null) return;
    InspectorNode? find(InspectorNode node) {
      if (node.id == id) return node;
      for (final c in node.children) {
        if (find(c) case final hit?) return hit;
      }
      return null;
    }

    final hit = root == null ? null : find(root!);
    if (hit != null) await _loadProperties(hit);
  }

  Future<void> select(InspectorNode node) async {
    if (node.id != null) {
      await debugger.callExtension('$_service.setSelectionById', {'arg': node.id!, 'objectGroup': _group});
    }
    await _loadProperties(node);
  }

  Future<void> _loadProperties(InspectorNode node) async {
    selected = node;
    properties = const [];
    _changed();
    if (node.id == null) return;
    final r = await debugger.callExtension('$_service.getProperties', {'arg': node.id!, 'objectGroup': _group});
    final list = r?['result'];
    if (list is! List || !identical(selected, node)) return;
    properties = [
      for (final raw in list.whereType<Map>())
        if (raw['name'] is String) (raw['name'] as String, raw['description'] as String? ?? ''),
    ];
    _changed();
  }

  void toggleCollapsed(InspectorNode node) {
    collapsed.contains(node.id) ? collapsed.remove(node.id) : collapsed.add(node.id);
    _changed();
  }

  Future<void> toggleSelectMode() async {
    final next = !selectMode;
    final r = await debugger.callExtension('$_service.show', {'enabled': '$next'});
    if (r == null) return;
    selectMode = next;
    _changed();
  }

  Future<void> toggleDebugPaint() async {
    final next = !debugPaint;
    final r = await debugger.callExtension('ext.flutter.debugPaint', {'enabled': '$next'});
    if (r == null) return;
    debugPaint = next;
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    debugger.removeListener(_onDebugger);
    debugger.onExtensionEvent = null;
    super.dispose();
  }
}

class WidgetTreeView extends StatefulWidget {
  const WidgetTreeView({super.key, required this.inspector, required this.onOpen});

  final WidgetTreeInspector inspector;
  final ValueChanged<EditTarget> onOpen;

  @override
  State<WidgetTreeView> createState() => _WidgetTreeViewState();
}

class _WidgetTreeViewState extends State<WidgetTreeView> {
  WidgetTreeInspector get _i => widget.inspector;

  @override
  void initState() {
    super.initState();
    _i.onNavigate = widget.onOpen;
    if (_i.debugger.connected && _i.root == null) unawaited(_i.refresh());
  }

  void _pick(InspectorNode node) {
    unawaited(_i.select(node));
    final path = node.path, line = node.line;
    if (path != null && line != null) widget.onOpen(EditTarget(path, line - 1, (node.column ?? 1) - 1));
  }

  Widget _toggle(String tip, IconData icon, bool on, VoidCallback? onPressed, ColorScheme scheme) => IconButton(
    tooltip: tip,
    iconSize: 15,
    visualDensity: VisualDensity.compact,
    color: on ? scheme.primary : null,
    onPressed: onPressed,
    icon: Icon(icon),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _i,
      builder: (_, _) {
        if (!_i.debugger.connected) {
          return Center(child: Text('Run the app in debug mode to inspect its widgets.', style: TextStyle(color: scheme.outline)));
        }
        final rows = flattenTree(_i.root, _i.collapsed);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _toggle('Refresh the tree', Icons.refresh, false, _i.loading ? null : _i.refresh, scheme),
                _toggle(_i.selectMode ? 'Stop picking on the device' : 'Pick a widget on the device', Icons.ads_click, _i.selectMode, _i.toggleSelectMode, scheme),
                _toggle('Show layout bounds on the device', Icons.border_outer, _i.debugPaint, _i.toggleDebugPaint, scheme),
                if (_i.loading) const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                if (_i.error != null) Expanded(child: Text(_i.error!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.error))),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemExtent: 22,
                      itemBuilder: (_, i) {
                        final (node, depth) = rows[i];
                        final on = identical(node, _i.selected);
                        return Material(
                          color: on ? scheme.primary.withValues(alpha: .14) : Colors.transparent,
                          child: InkWell(
                            onTap: () => _pick(node),
                            child: Padding(
                              padding: EdgeInsets.only(left: 6.0 + depth * 12),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 16,
                                    child: node.children.isEmpty
                                        ? null
                                        : InkWell(
                                            onTap: () => _i.toggleCollapsed(node),
                                            child: Icon(_i.collapsed.contains(node.id) ? Icons.chevron_right : Icons.expand_more, size: 15),
                                          ),
                                  ),
                                  Flexible(
                                    child: Text(
                                      node.type,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12.5, color: on ? scheme.primary : null),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  VerticalDivider(width: 1, color: scheme.outlineVariant),
                  Expanded(
                    flex: 2,
                    child: _i.selected == null
                        ? Center(child: Text('Pick a widget to see its properties.', style: TextStyle(fontSize: 12, color: scheme.outline)))
                        : SelectionArea(
                            child: ListView(
                              padding: const EdgeInsets.all(8),
                              children: [
                                Text(_i.selected!.description, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                const SizedBox(height: 6),
                                for (final (name, value) in _i.properties)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2),
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(text: '$name: ', style: TextStyle(color: scheme.outline)),
                                          TextSpan(text: value),
                                        ],
                                      ),
                                      style: const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: monoFallback, fontSize: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
