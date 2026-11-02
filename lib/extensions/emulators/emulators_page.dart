import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/files.dart';
import '../../core/windows.dart';
import '../../modules/devices/models/device.dart';
import '../../modules/devices/services/adb_service.dart';
import '../../modules/devices/view/workspace/display_editor.dart';
import 'avd_service.dart';
import 'system_images_dialog.dart';
import '../../core/history.dart';
import '../../core/compact_dropdown.dart';

class EmulatorsPage extends StatefulWidget {
  const EmulatorsPage({super.key});

  @override
  State<EmulatorsPage> createState() => _EmulatorsPageState();
}

class _EmulatorsPageState extends State<EmulatorsPage> {
  late final _svc = AvdService(context.read<AdbService>().tools);
  List<Avd>? _avds;
  final _busy = <String>{};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    // Picks up emulators started/stopped outside DevKit.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final avds = await _svc.list();
    if (mounted) setState(() => _avds = avds);
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), width: 460));

  Future<void> _do(Avd a, Future<void> Function() action, String done) async {
    setState(() => _busy.add(a.name));
    try {
      await action();
      History.activity('emulator', done, {'avd': a.name});
      _toast(done);
    } catch (e) {
      _toast('Failed: $e');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    await _load();
    if (mounted) setState(() => _busy.remove(a.name));
  }

  Future<void> _start(Avd a, {bool cold = false, bool wipe = false, bool headless = false}) async {
    final err = await _svc.start(a, coldBoot: cold, wipeData: wipe, noWindow: headless);
    if (err != null) return _toast(err);
    _do(a, () async {}, wipe ? 'Wiping & booting ${a.displayName}…' : 'Starting ${a.displayName}…');
  }

  Future<bool> _confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 380, child: Text(body)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _onMenu(Avd a, String action) async {
    switch (action) {
      case 'cold':
        await _start(a, cold: true);
      case 'headless':
        await _start(a, headless: true);
      case 'wipe':
        if (!await _confirm('Wipe data?', 'All apps and data on ${a.displayName} will be erased.', 'Wipe')) return;
        if (a.running) {
          await _svc.stop(a);
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        await _do(a, () => _svc.wipe(a), '${a.displayName} wiped — next boot is a fresh device');
      case 'wipeStart':
        if (!await _confirm('Wipe & start?', 'All apps and data on ${a.displayName} will be erased.', 'Wipe')) return;
        await _start(a, wipe: true);
      case 'edit':
        await _edit(a);
      case 'folder':
        await revealInExplorer(a.dir.path);
      case 'delete':
        if (!await _confirm('Delete ${a.displayName}?', 'The AVD and all its data will be removed.', 'Delete')) return;
        if (a.running) await _svc.stop(a);
        await _do(a, () => _svc.delete(a), '${a.displayName} deleted');
    }
  }

  void _openWorkspace(Avd a) {
    final serial = a.serial;
    if (serial == null) return;
    openWorkspaceWindow(
      Device(
        id: serial,
        serial: serial,
        name: a.displayName,
        model: a.displayName,
        adb: AdbState.connected,
        online: true,
      ),
    );
  }

  Future<void> _edit(Avd a) async {
    final changes = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _EditDialog(avd: a),
    );
    if (changes == null) return;
    await _do(
      a,
      () => _svc.updateConfig(a, changes),
      a.running ? 'Saved — restart ${a.displayName} to apply' : '${a.displayName} updated',
    );
  }

  Future<void> _create() async {
    var images = _svc.systemImages();
    if (images.isEmpty) {
      _toast('No system images yet — download one first');
      await showSystemImagesDialog(context, _svc);
      images = _svc.systemImages();
      if (images.isEmpty || !mounted) return;
    }
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _CreateDialog(svc: _svc, images: images),
    );
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final avds = _avds;
    final noEmulator = _svc.emulatorExe == null;

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
                  Text('Emulators', style: text.headlineSmall),
                  Text(
                    noEmulator
                        ? 'Android emulator not found in the SDK'
                        : 'Android Virtual Devices · ${_svc.avdHome.path}',
                    style: text.bodySmall?.copyWith(color: noEmulator ? scheme.error : scheme.outline),
                  ),
                ],
              ),
              const Spacer(),
              IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh)),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: noEmulator ? null : () => showSystemImagesDialog(context, _svc),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('System images'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: noEmulator ? null : _create,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Create AVD'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: avds == null
                ? const Center(child: CircularProgressIndicator())
                : avds.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.phone_android, size: 56, color: scheme.outline),
                        const SizedBox(height: 12),
                        Text('No virtual devices yet', style: text.titleMedium),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: noEmulator ? null : _create,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Create AVD'),
                        ),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, c) => GridView.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: (c.maxWidth / 360).floor().clamp(1, 4),
                        mainAxisExtent: 196,
                        crossAxisSpacing: 12,
                        mainAxisSpacing: 12,
                      ),
                      itemCount: avds.length,
                      itemBuilder: (_, i) {
                        final a = avds[i];
                        return _AvdCard(
                          avd: a,
                          busy: _busy.contains(a.name),
                          onStart: () => _start(a),
                          onStop: () => _do(a, () => _svc.stop(a), 'Stopping ${a.displayName}…'),
                          onOpen: () => _openWorkspace(a),
                          onMenu: (v) => _onMenu(a, v),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _AvdCard extends StatelessWidget {
  const _AvdCard({
    required this.avd,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onOpen,
    required this.onMenu,
  });

  final Avd avd;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onOpen;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final a = avd;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.outline);
    final landscape = (a.width ?? 0) > (a.height ?? 0);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: a.running ? scheme.primary.withValues(alpha: .12) : scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    landscape ? Icons.tablet_android : Icons.phone_android,
                    color: a.running ? scheme.primary : scheme.outline,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.displayName, style: text.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: a.running ? const Color(0xFF10B981) : scheme.outlineVariant,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(a.running ? 'Running · ${a.serial}' : 'Stopped', style: muted),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: onMenu,
                  itemBuilder: (_) => [
                    if (!a.running) ...const [
                      PopupMenuItem(height: 30, value: 'cold', child: Text('Cold boot')),
                      PopupMenuItem(height: 30, value: 'headless', child: Text('Start headless (no window)')),
                      PopupMenuItem(height: 30, value: 'wipeStart', child: Text('Wipe data & start')),
                    ],
                    const PopupMenuItem(height: 30, value: 'wipe', child: Text('Wipe data')),
                    const PopupMenuItem(height: 30, value: 'edit', child: Text('Edit hardware…')),
                    const PopupMenuItem(height: 30, value: 'folder', child: Text('Show in Explorer')),
                    const PopupMenuDivider(),
                    PopupMenuItem(height: 30, 
                      value: 'delete',
                      child: Text('Delete', style: TextStyle(color: scheme.error)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (a.api != null) _Tag('API ${a.api}'),
                if (a.variant != null) _Tag(a.variant!.replaceAll('_', ' ')),
                if (a.abi != null) _Tag(a.abi!),
                if (a.width != null && a.height != null) _Tag('${a.width}×${a.height} · ${a.density ?? '?'} dpi'),
                if (a.ramMb != null) _Tag('${a.ramMb} MB RAM'),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (a.running) ...[
                  FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Workspace'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: onStop,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Stop'),
                  ),
                ] else
                  FilledButton.icon(
                    onPressed: onStart,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    );
  }
}

class _HardwareFields extends StatelessWidget {
  const _HardwareFields({
    required this.w,
    required this.h,
    required this.dpi,
    required this.ram,
    required this.onPreset,
    this.showPresets = true,
  });

  final TextEditingController w;
  final TextEditingController h;
  final TextEditingController dpi;
  final TextEditingController ram;
  final ValueChanged<DisplayPreset> onPreset;
  final bool showPresets;

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    Widget f(TextEditingController c, String label) => Expanded(
      child: TextField(
        controller: c,
        inputFormatters: digits,
        decoration: InputDecoration(labelText: label),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            f(w, 'Width px'),
            const SizedBox(width: 8),
            f(h, 'Height px'),
            const SizedBox(width: 8),
            f(dpi, 'DPI'),
            const SizedBox(width: 8),
            f(ram, 'RAM MB'),
          ],
        ),
        if (showPresets) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in displayPresets)
                ActionChip(label: Text(p.label), visualDensity: VisualDensity.compact, onPressed: () => onPreset(p)),
            ],
          ),
        ],
      ],
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({required this.preset, required this.selected, required this.onTap});

  final DisplayPreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = preset;
    final scheme = Theme.of(context).colorScheme;
    final landscape = p.w > p.h;
    final icon = p.inches >= 20
        ? Icons.desktop_windows_outlined
        : p.label.startsWith('POS')
        ? Icons.point_of_sale
        : p.inches >= 8
        ? Icons.tablet_android
        : Icons.smartphone;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: .08) : scheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: selected ? scheme.primary : scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.label,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${p.inches}" · ${p.w}×${p.h}\n${p.dpi} dpi${landscape ? ' · landscape' : ''}',
                    style: TextStyle(fontSize: 10.5, color: scheme.outline, height: 1.3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

int _ramFor(DisplayPreset p) => p.inches >= 15 ? 4096 : (p.inches >= 8 ? 3072 : 2048);

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.avd});

  final Avd avd;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final _name = TextEditingController(text: widget.avd.displayName);
  late final _w = TextEditingController(text: '${widget.avd.width ?? ''}');
  late final _h = TextEditingController(text: '${widget.avd.height ?? ''}');
  late final _dpi = TextEditingController(text: '${widget.avd.density ?? ''}');
  late final _ram = TextEditingController(text: '${widget.avd.ramMb ?? ''}');

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Edit ${widget.avd.displayName}'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          const SizedBox(height: 12),
          _HardwareFields(
            w: _w,
            h: _h,
            dpi: _dpi,
            ram: _ram,
            onPreset: (p) => setState(() {
              _w.text = '${p.w}';
              _h.text = '${p.h}';
              _dpi.text = '${p.dpi}';
            }),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'avd.ini.displayname': _name.text.trim(),
          if (_w.text.isNotEmpty) 'hw.lcd.width': _w.text,
          if (_h.text.isNotEmpty) 'hw.lcd.height': _h.text,
          if (_dpi.text.isNotEmpty) 'hw.lcd.density': _dpi.text,
          if (_ram.text.isNotEmpty) 'hw.ramSize': _ram.text,
        }),
        child: const Text('Save'),
      ),
    ],
  );
}

class _CreateDialog extends StatefulWidget {
  const _CreateDialog({required this.svc, required this.images});

  final AvdService svc;
  final List<SystemImage> images;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

class _CreateDialogState extends State<_CreateDialog> {
  final _name = TextEditingController(text: 'POS 15.6"');
  late var _image = widget.images.first;
  final _w = TextEditingController(text: '1920');
  final _h = TextEditingController(text: '1080');
  final _dpi = TextEditingController(text: '160');
  final _ram = TextEditingController(text: '4096');
  final _disk = TextEditingController(text: '6');
  String? _error;
  var _busy = false;

  void _applyPreset(DisplayPreset p) => setState(() {
    _w.text = '${p.w}';
    _h.text = '${p.h}';
    _dpi.text = '${p.dpi}';
    _ram.text = '${_ramFor(p)}';
    _disk.text = p.inches >= 15 ? '8' : '6';
    _name.text = p.label;
  });

  String get _id => _name.text.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  Future<void> _submit() async {
    final id = _id;
    final w = int.tryParse(_w.text), h = int.tryParse(_h.text), d = int.tryParse(_dpi.text);
    final ram = int.tryParse(_ram.text), disk = int.tryParse(_disk.text);
    if (id.isEmpty || w == null || h == null || d == null || ram == null || disk == null) {
      return setState(() => _error = 'Fill in all fields');
    }
    if ((await widget.svc.list()).any((a) => a.name == id)) {
      return setState(() => _error = 'An AVD named "$id" already exists');
    }
    setState(() => _busy = true);
    try {
      History.activity('emulator', 'Create AVD $id', {'image': _image.label});
      await widget.svc.create(
        name: id,
        displayName: _name.text.trim(),
        image: _image,
        width: w,
        height: h,
        density: d,
        ramMb: ram,
        diskGb: disk,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = 'Failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create virtual device'),
    content: SizedBox(
      width: 660,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'DEVICE SIZE',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline, letterSpacing: .6),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in displayPresets)
                _PresetCard(
                  preset: p,
                  selected: _w.text == '${p.w}' && _h.text == '${p.h}' && _dpi.text == '${p.dpi}',
                  onTap: () => _applyPreset(p),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: 'Name', helperText: 'ID: $_id'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          CompactDropdown<SystemImage>(
            initialValue: _image,
            decoration: const InputDecoration(labelText: 'System image'),
            items: [for (final i in widget.images) DropdownMenuItem(value: i, child: Text(i.label))],
            onChanged: (v) => setState(() => _image = v ?? _image),
          ),
          const SizedBox(height: 12),
          _HardwareFields(w: _w, h: _h, dpi: _dpi, ram: _ram, showPresets: false, onPreset: _applyPreset),
          const SizedBox(height: 12),
          SizedBox(
            width: 140,
            child: TextField(
              controller: _disk,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Storage GB'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _submit, child: const Text('Create')),
    ],
  );
}
