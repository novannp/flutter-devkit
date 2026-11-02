import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/files.dart';
import '../cubit/devices_cubit.dart';
import '../models/device.dart';
import '../services/adb_service.dart';
import '../services/device_adb.dart';
import '../services/screen_input.dart';
import 'workspace/embedded_scrcpy.dart';
import 'workspace/screen_panel.dart';
import 'workspace/workspace_page.dart';

const _prefPanel = 'multi_panel_width';
const _prefFast = 'multi_fast';

/// Multiple device screens in one window + a full panel (Flutter, Logcat, etc.) for the selected device.
class MultiScreenPage extends StatefulWidget {
  const MultiScreenPage({super.key});

  @override
  State<MultiScreenPage> createState() => _MultiScreenPageState();
}

class _MultiScreenPageState extends State<MultiScreenPage> {
  /// Empty at first: mirroring is heavy, so nothing starts until someone picks a device.
  final _picked = <String>{};
  final _devs = <String, DeviceAdb>{};
  final _controllers = <String, ScreenMirrorController>{};
  String? _selected;
  var _broadcast = false;
  var _fast = true;
  var _showPanel = true;
  var _panelWidth = 460.0;

  Timer? _probe;

  /// Screen size per device (from a screencap header), so tiles can match each device's shape.
  final _screenSizes = <String, Size>{};

  Future<void> _probeSizes() async {
    if (!mounted) return;
    final shown = context.read<DevicesCubit>().state.devices.where((d) => d.adb == AdbState.connected && _picked.contains(d.id)).toList();
    for (final d in shown) {
      if (d.adbTarget == null) continue;
      final bytes = await _dev(d).screenshot();
      if (!mounted || bytes == null || bytes.length < 24) continue;
      final v = ByteData.sublistView(bytes);
      final size = Size(v.getUint32(16).toDouble(), v.getUint32(20).toDouble());
      if (_screenSizes[d.id] != size) setState(() => _screenSizes[d.id] = size);
    }
  }

  @override
  void dispose() {
    _probe?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeSizes());
    // Catches rotation; cheap enough at this rate.
    _probe = Timer.periodic(const Duration(seconds: 8), (_) {
      if (TickerMode.valuesOf(context).enabled) _probeSizes();
    });
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _panelWidth = p.getDouble(_prefPanel) ?? _panelWidth;
        _fast = p.getBool(_prefFast) ?? true;
      });
    });
  }

  AdbService get _adb => context.read<AdbService>();

  DeviceAdb _dev(Device d) => _devs.putIfAbsent(d.id, () => DeviceAdb(_adb, d.adbTarget!));

  ScreenMirrorController _ctl(Device d) => _controllers.putIfAbsent(d.id, ScreenMirrorController.new);

  void _broadcastFrom(Device source, List<Device> shown, ScreenInput input) {
    if (!_broadcast) return;
    for (final d in shown) {
      if (d.id == source.id) continue;
      final size = _controllers[d.id]?.size;
      if (size == null && (input is TapInput || input is SwipeInput)) continue;
      applyInput(_dev(d), size ?? Size.zero, input);
    }
  }

  Future<void> _keyAll(List<Device> shown, String keycode) => Future.wait(shown.map((d) => _dev(d).key(keycode)));

  Future<void> _screenshotAll(List<Device> shown) async {
    final dir = await Directory('${(await outputDir()).path}${Platform.pathSeparator}multi_${timestamp()}').create();
    for (final d in shown) {
      final bytes = await _dev(d).screenshot();
      if (bytes != null) {
        await File('${dir.path}${Platform.pathSeparator}${safeFileName(d.displayName)}.png').writeAsBytes(bytes);
      }
    }
    revealInExplorer(dir.path);
  }

  static const _header = 40.0, _gap = 10.0;

  Size _shape(Device d) => _controllers[d.id]?.size ?? _screenSizes[d.id] ?? const Size(9, 16);

  /// Justified rows (like a photo gallery): each tile is as wide as its device's aspect ratio needs,
  /// and the row count that makes the smallest screen biggest wins.
  List<List<(Device, Size)>> _layout(List<Device> shown, Size area) {
    final aspects = [for (final d in shown) _shape(d).width / _shape(d).height];
    List<List<(Device, Size)>>? best;
    var bestScore = -1.0;
    for (var rows = 1; rows <= shown.length; rows++) {
      // Split in order into `rows` groups with roughly equal total aspect.
      final total = aspects.reduce((a, b) => a + b);
      final groups = <List<int>>[[]];
      var acc = 0.0;
      for (var k = 0; k < shown.length; k++) {
        final remainingRows = rows - groups.length;
        final remainingItems = shown.length - k;
        if (groups.last.isNotEmpty &&
            remainingRows > 0 &&
            (acc >= total * groups.length / rows || remainingItems <= remainingRows)) {
          groups.add([]);
        }
        groups.last.add(k);
        acc += aspects[k];
      }
      final rowH = (area.height - _gap * (groups.length - 1)) / groups.length - _header;
      if (rowH <= 0) continue;
      final layout = <List<(Device, Size)>>[];
      var minArea = double.infinity;
      for (final g in groups) {
        final sumA = g.fold(0.0, (a, k) => a + aspects[k]);
        final h = min(rowH, (area.width - _gap * (g.length - 1)) / sumA);
        layout.add([for (final k in g) (shown[k], Size(aspects[k] * h, h + _header))]);
        for (final k in g) {
          minArea = min(minArea, aspects[k] * h * h);
        }
      }
      if (minArea > bestScore) {
        bestScore = minArea;
        best = layout;
      }
    }
    return best ??
        [
          for (final d in shown) [(d, Size(area.width, area.height / shown.length))],
        ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BlocBuilder<DevicesCubit, DevicesState>(
      builder: (context, state) {
        final connected = state.devices.where((d) => d.adb == AdbState.connected && d.adbTarget != null).toList();
        final shown = connected.where((d) => _picked.contains(d.id)).toList();
        final selected = shown.where((d) => d.id == _selected).firstOrNull ?? shown.firstOrNull;
        final useFast = _fast && !_broadcast && _adb.tools.scrcpy != null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              total: connected.length,
              shown: shown.length,
              broadcast: _broadcast,
              fast: _fast,
              showPanel: _showPanel,
              onBroadcast: (v) => setState(() => _broadcast = v),
              onFast: (v) {
                setState(() => _fast = v);
                SharedPreferences.getInstance().then((p) => p.setBool(_prefFast, v));
              },
              onPanel: () => setState(() => _showPanel = !_showPanel),
              onBack: () => _keyAll(shown, 'KEYCODE_BACK'),
              onHome: () => _keyAll(shown, 'KEYCODE_HOME'),
              onWake: () => _keyAll(shown, 'KEYCODE_WAKEUP'),
              onScreenshotAll: () => _screenshotAll(shown),
            ),
            if (connected.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final d in connected)
                      FilterChip(
                        label: Text(d.displayName),
                        selected: _picked.contains(d.id),
                        onSelected: (v) {
                          setState(() => v ? _picked.add(d.id) : _picked.remove(d.id));
                          if (v) unawaited(_probeSizes());
                        },
                      ),
                  ],
                ),
              ),
            Expanded(
              child: shown.isEmpty
                  ? _Empty(hasDevices: connected.isNotEmpty)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
                            child: LayoutBuilder(
                              builder: (context, box) {
                                final rows = _layout(shown, box.biggest);
                                return Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (final (ri, row) in rows.indexed) ...[
                                      if (ri > 0) const SizedBox(height: _gap),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          for (final (ti, (d, size)) in row.indexed) ...[
                                            if (ti > 0) const SizedBox(width: _gap),
                                            SizedBox(
                                              // Keep the header's buttons usable on very narrow portrait tiles.
                                              width: max(size.width, 240),
                                              height: size.height,
                                              child: _Tile(
                                                key: ValueKey('${d.id}-$useFast'),
                                                device: d,
                                                dev: _dev(d),
                                                controller: _ctl(d),
                                                fast: useFast,
                                                selected: selected?.id == d.id,
                                                broadcast: _broadcast,
                                                onSelect: () => setState(() => _selected = d.id),
                                                onInput: (input) => _broadcastFrom(d, shown, input),
                                                onHide: () => setState(() => _picked.remove(d.id)),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ],
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                        if (_showPanel && selected != null) ...[
                          MouseRegion(
                            cursor: SystemMouseCursors.resizeColumn,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onHorizontalDragUpdate: (e) =>
                                  setState(() => _panelWidth = (_panelWidth - e.delta.dx).clamp(360.0, 900.0)),
                              onHorizontalDragEnd: (_) =>
                                  SharedPreferences.getInstance().then((p) => p.setDouble(_prefPanel, _panelWidth)),
                              child: SizedBox(width: 6, child: VerticalDivider(width: 1, color: scheme.outlineVariant)),
                            ),
                          ),
                          SizedBox(
                            width: _panelWidth,
                            // Keep all panels alive so each device's logcat/flutter run isn't interrupted when switching selection.
                            child: IndexedStack(
                              index: shown.indexOf(selected),
                              children: [
                                for (final d in shown)
                                  DeviceWorkspacePage(key: ValueKey('panel-${d.id}'), device: d, panelOnly: true),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.total,
    required this.shown,
    required this.broadcast,
    required this.fast,
    required this.showPanel,
    required this.onBroadcast,
    required this.onFast,
    required this.onPanel,
    required this.onBack,
    required this.onHome,
    required this.onWake,
    required this.onScreenshotAll,
  });

  final int total, shown;
  final bool broadcast, fast, showPanel;
  final ValueChanged<bool> onBroadcast, onFast;
  final VoidCallback onPanel, onBack, onHome, onWake, onScreenshotAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget icon(IconData i, String tip, VoidCallback onTap) =>
        IconButton(tooltip: tip, onPressed: onTap, icon: Icon(i, size: 20));

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 10),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Multi Screen', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text('$shown of $total devices', style: TextStyle(color: scheme.outline)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, icon: Icon(Icons.bolt, size: 16), label: Text('Fast')),
                  ButtonSegment(value: false, icon: Icon(Icons.photo_outlined, size: 16), label: Text('Lite')),
                ],
                selected: {fast},
                onSelectionChanged: (s) => onFast(s.first),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Taps, swipes, and typing on one screen go to all devices (switches to Lite mode)',
                child: FilterChip(
                  avatar: Icon(Icons.cell_tower, size: 16, color: broadcast ? Colors.orange.shade700 : null),
                  label: const Text('Broadcast input'),
                  selected: broadcast,
                  onSelected: onBroadcast,
                ),
              ),
              const SizedBox(width: 8),
              icon(Icons.arrow_back_ios_new, 'Back all', onBack),
              icon(Icons.circle_outlined, 'Home all', onHome),
              icon(Icons.light_mode_outlined, 'Wake all', onWake),
              icon(Icons.photo_library_outlined, 'Screenshot all', onScreenshotAll),
              icon(
                showPanel ? Icons.view_sidebar : Icons.view_sidebar_outlined,
                showPanel ? 'Hide panel' : 'Show panel',
                onPanel,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.device,
    required this.dev,
    required this.controller,
    required this.fast,
    required this.selected,
    required this.broadcast,
    required this.onSelect,
    required this.onInput,
    required this.onHide,
  });

  final Device device;
  final DeviceAdb dev;
  final ScreenMirrorController controller;
  final bool fast, selected, broadcast;
  final VoidCallback onSelect, onHide;
  final void Function(ScreenInput) onInput;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      icon: Icon(icon),
    );
    final borderColor = selected ? scheme.primary : (broadcast ? Colors.orange : scheme.outlineVariant);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        // Fixed width so selecting a tile doesn't shift the embedded screens.
        border: Border.all(color: borderColor, width: 2),
        boxShadow: [
          if (selected)
            BoxShadow(color: scheme.primary.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // The header is the click target for selecting a device, since clicks on the scrcpy screen go to the native window.
          InkWell(
            onTap: onSelect,
            child: Container(
              height: 38,
              padding: const EdgeInsets.only(left: 12, right: 4),
              color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: device.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                          ),
                          if (device.model != null && device.model != device.displayName)
                            TextSpan(
                              text: '  ${device.model}',
                              style: TextStyle(color: scheme.outline, fontSize: 11.5),
                            ),
                        ],
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  btn(Icons.arrow_back_ios_new, 'Back', () => dev.key('KEYCODE_BACK')),
                  btn(Icons.circle_outlined, 'Home', () => dev.key('KEYCODE_HOME')),
                  btn(Icons.crop_square, 'Recent', () => dev.key('KEYCODE_APP_SWITCH')),
                  btn(Icons.close, 'Hide', onHide),
                ],
              ),
            ),
          ),
          Expanded(
            child: fast
                ? EmbeddedScrcpy(adb: dev.adb, target: dev.target, maxSize: 1280)
                : ScreenPanel(dev: dev, controller: controller, onInput: onInput, compact: true),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasDevices});

  final bool hasDevices;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.grid_view_rounded, size: 48, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          Text(
            hasDevices
                ? 'Select devices above to show them.'
                : 'No devices connected via ADB yet.\nPlug in USB, turn on wireless debugging, or use "Pair device".',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}
