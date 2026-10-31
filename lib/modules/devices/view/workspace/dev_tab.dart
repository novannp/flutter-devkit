import 'package:flutter/material.dart';

import '../../services/device_adb.dart';
import 'display_editor.dart';

/// Developer, battery, network, and display toggles commonly used while testing.
class DevTab extends StatefulWidget {
  const DevTab({super.key, required this.dev});

  final DeviceAdb dev;

  @override
  State<DevTab> createState() => _DevTabState();
}

const _reads = {
  'stayon': 'settings get global stay_on_while_plugged_in',
  'touches': 'settings get system show_touches',
  'pointer': 'settings get system pointer_location',
  'anim': 'settings get global window_animation_scale',
  'layout': 'getprop debug.layout',
  'night': 'cmd uimode night',
  'font': 'settings get system font_scale',
  'size': 'wm size',
  'density': 'wm density',
  'battery': 'dumpsys battery',
  'wifi': 'settings get global wifi_on',
  'data': 'settings get global mobile_data',
  'airplane': 'settings get global airplane_mode_on',
};

class _DevTabState extends State<DevTab> {
  Map<String, String> _v = const {};
  var _batteryLevel = 50.0;
  var _loading = false;

  DeviceAdb get dev => widget.dev;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final script = _reads.entries.map((e) => 'echo "@@${e.key}"; ${e.value} 2>/dev/null').join('; ');
    final out = await dev.sh(script);
    final v = <String, String>{};
    String? key;
    final buf = StringBuffer();
    for (final line in out.split('\n')) {
      if (line.startsWith('@@')) {
        if (key != null) v[key] = buf.toString().trim();
        key = line.substring(2).trim();
        buf.clear();
      } else {
        buf.writeln(line);
      }
    }
    if (key != null) v[key] = buf.toString().trim();
    if (!mounted) return;
    setState(() {
      _v = v;
      _loading = false;
      _batteryLevel = double.tryParse(_batteryField('level') ?? '') ?? _batteryLevel;
    });
  }

  String? _batteryField(String name) => RegExp('$name: (.+)').firstMatch(_v['battery'] ?? '')?[1]?.trim();

  Future<void> _run(String cmd) async {
    await dev.shell(cmd);
    await _load();
  }

  bool _on(String key) => _v[key] != null && _v[key] != '0' && _v[key] != 'null' && _v[key] != 'false';

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: Theme.of(context).colorScheme.outline),
    ),
  );

  Widget _toggle(String title, bool value, String onCmd, String offCmd, {String? subtitle}) => SwitchListTile(
    dense: true,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: (v) => _run(v ? onCmd : offCmd),
  );

  // debug.* props need a "ping" to all apps to take effect without a restart.
  static const _pokeProps = 'service call activity 1599295570 > /dev/null';

  @override
  Widget build(BuildContext context) {
    if (_v.isEmpty) return const Center(child: CircularProgressIndicator());
    final animOff = _v['anim'] == '0' || _v['anim'] == '0.0';
    final unplugged = _batteryField('AC powered') == 'false' && _batteryField('USB powered') == 'false';

    return ListView(
      children: [
        Row(
          children: [
            _section('Developer'),
            const Spacer(),
            if (_loading) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh, size: 18)),
          ],
        ),
        _toggle('Stay awake while charging', _on('stayon'), 'svc power stayon true', 'svc power stayon false'),
        _toggle(
          'Show touches',
          _on('touches'),
          'settings put system show_touches 1',
          'settings put system show_touches 0',
        ),
        _toggle(
          'Pointer location',
          _on('pointer'),
          'settings put system pointer_location 1',
          'settings put system pointer_location 0',
        ),
        _toggle(
          'Layout bounds',
          _v['layout'] == 'true',
          'setprop debug.layout true; $_pokeProps',
          'setprop debug.layout false; $_pokeProps',
          subtitle: 'Widget/view outlines for checking padding',
        ),
        _toggle(
          'Disable animations',
          animOff,
          'settings put global window_animation_scale 0; settings put global transition_animation_scale 0; settings put global animator_duration_scale 0',
          'settings put global window_animation_scale 1; settings put global transition_animation_scale 1; settings put global animator_duration_scale 1',
        ),
        _toggle('Dark mode', (_v['night'] ?? '').contains('yes'), 'cmd uimode night yes', 'cmd uimode night no'),
        ListTile(
          dense: true,
          title: const Text('Font size'),
          trailing: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: '0.85', label: Text('S')),
              ButtonSegment(value: '1.0', label: Text('M')),
              ButtonSegment(value: '1.3', label: Text('L')),
              ButtonSegment(value: '1.5', label: Text('XL')),
            ],
            selected: {
              switch (double.tryParse(_v['font'] ?? '') ?? 1.0) {
                < 0.95 => '0.85',
                < 1.15 => '1.0',
                < 1.4 => '1.3',
                _ => '1.5',
              },
            },
            onSelectionChanged: (v) => _run('settings put system font_scale ${v.first}'),
          ),
        ),
        _section('Display'),
        DisplayEditor(sizeOut: _v['size'] ?? '', densityOut: _v['density'] ?? '', onRun: _run),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _run('settings put system accelerometer_rotation 1'),
                child: const Text('Auto-rotate'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _run('settings put system accelerometer_rotation 0; settings put system user_rotation 0'),
                child: const Text('Portrait'),
              ),
              OutlinedButton(
                onPressed: () =>
                    _run('settings put system accelerometer_rotation 0; settings put system user_rotation 1'),
                child: const Text('Landscape'),
              ),
            ],
          ),
        ),
        _section('Battery'),
        ListTile(
          dense: true,
          title: Text('Level ${_batteryLevel.round()}%${unplugged ? ' · simulated unplugged' : ''}'),
          subtitle: Slider(
            value: _batteryLevel.clamp(0, 100),
            max: 100,
            divisions: 20,
            label: '${_batteryLevel.round()}%',
            onChanged: (v) => setState(() => _batteryLevel = v),
            onChangeEnd: (v) => _run('dumpsys battery set level ${v.round()}'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton(onPressed: () => _run('dumpsys battery unplug'), child: const Text('Unplug charger')),
              OutlinedButton(onPressed: () => _run('dumpsys battery set level 5'), child: const Text('Low battery 5%')),
              FilledButton.tonal(onPressed: () => _run('dumpsys battery reset'), child: const Text('Reset battery')),
            ],
          ),
        ),
        _section('Network'),
        _toggle(
          'Wi-Fi',
          _on('wifi'),
          'svc wifi enable',
          'svc wifi disable',
          subtitle: 'Careful: ADB Wi-Fi disconnects if turned off',
        ),
        _toggle('Mobile data', _on('data'), 'svc data enable', 'svc data disable'),
        _toggle(
          'Airplane mode',
          _on('airplane'),
          'cmd connectivity airplane-mode enable',
          'cmd connectivity airplane-mode disable',
          subtitle: 'For testing offline mode',
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
