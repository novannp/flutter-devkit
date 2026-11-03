import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DisplayPreset {
  const DisplayPreset(this.label, this.inches, this.w, this.h, this.dpi);

  final String label;
  final double inches;
  final int w;
  final int h;
  final int dpi;
}

// Densities follow what manufacturers usually ship, not the raw physical dpi.
const displayPresets = [
  DisplayPreset('Phone small', 5.5, 720, 1280, 320),
  DisplayPreset('Phone', 6.1, 1080, 2340, 440),
  DisplayPreset('Phone large', 6.7, 1440, 3120, 560),
  DisplayPreset('Tablet 8"', 8, 1200, 1920, 240),
  DisplayPreset('Tablet 10.1"', 10.1, 1920, 1200, 240),
  DisplayPreset('Tablet 11"', 11, 2560, 1600, 320),
  DisplayPreset('Display 10.1"', 10.1, 1280, 800, 160),
  DisplayPreset('Display 15.6"', 15.6, 1920, 1080, 160),
  DisplayPreset('Display 21.5"', 21.5, 1920, 1080, 160),
  DisplayPreset('Portrait 24"', 24, 1080, 1920, 160),
  DisplayPreset('Large 32"', 32, 1920, 1080, 120),
  DisplayPreset('Large 4K 43"', 43, 3840, 2160, 240),
];

class DisplaySize {
  const DisplaySize(this.w, this.h);

  final int w;
  final int h;

  static DisplaySize? parse(String? s) {
    final m = RegExp(r'(\d+)x(\d+)').firstMatch(s ?? '');
    return m == null ? null : DisplaySize(int.parse(m[1]!), int.parse(m[2]!));
  }
}

/// Edits `wm size` / `wm density`. [sizeOut]/[densityOut] are raw command outputs (Physical + optional Override).
class DisplayEditor extends StatefulWidget {
  const DisplayEditor({super.key, required this.sizeOut, required this.densityOut, required this.onRun});

  final String sizeOut;
  final String densityOut;
  final Future<void> Function(String cmd) onRun;

  @override
  State<DisplayEditor> createState() => _DisplayEditorState();
}

class _DisplayEditorState extends State<DisplayEditor> {
  final _w = TextEditingController();
  final _h = TextEditingController();
  final _dpi = TextEditingController();
  final _inches = TextEditingController();
  var _busy = false;

  String? _line(String out, String key) => RegExp('$key[^:]*:\\s*(.+)').firstMatch(out)?[1]?.trim();

  DisplaySize? get _physical => DisplaySize.parse(_line(widget.sizeOut, 'Physical'));
  DisplaySize? get _override => DisplaySize.parse(_line(widget.sizeOut, 'Override'));
  int? get _physicalDpi => int.tryParse(_line(widget.densityOut, 'Physical') ?? '');
  int? get _overrideDpi => int.tryParse(_line(widget.densityOut, 'Override') ?? '');
  bool get _overridden => _override != null || _overrideDpi != null;

  @override
  void initState() {
    super.initState();
    _fillCurrent();
  }

  @override
  void didUpdateWidget(DisplayEditor old) {
    super.didUpdateWidget(old);
    if (old.sizeOut != widget.sizeOut || old.densityOut != widget.densityOut) _fillCurrent();
  }

  @override
  void dispose() {
    for (final c in [_w, _h, _dpi, _inches]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fillCurrent() {
    final s = _override ?? _physical;
    final d = _overrideDpi ?? _physicalDpi;
    if (s != null) {
      _w.text = '${s.w}';
      _h.text = '${s.h}';
    }
    if (d != null) _dpi.text = '$d';
  }

  int? get _wi => int.tryParse(_w.text);
  int? get _hi => int.tryParse(_h.text);
  int? get _di => int.tryParse(_dpi.text);

  /// Physical dpi for the entered diagonal — what a real panel of that size would have.
  int? get _physicalFromInches {
    final inch = double.tryParse(_inches.text.replaceAll(',', '.'));
    if (inch == null || inch <= 0 || _wi == null || _hi == null) return null;
    return (sqrt(_wi! * _wi! + _hi! * _hi!) / inch).round();
  }

  void _applyPreset(DisplayPreset p) {
    setState(() {
      _w.text = '${p.w}';
      _h.text = '${p.h}';
      _dpi.text = '${p.dpi}';
      _inches.text = p.inches.toString().replaceAll(RegExp(r'\.0$'), '');
    });
  }

  Future<void> _apply() async {
    if (_wi == null || _hi == null || _di == null) return;
    setState(() => _busy = true);
    await widget.onRun('wm size ${_wi}x$_hi; wm density $_di');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reset() async {
    setState(() => _busy = true);
    await widget.onRun('wm size reset; wm density reset');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: scheme.outline);
    final phys = _physical;
    final w = _wi, h = _hi, d = _di;
    final dpW = w != null && d != null && d > 0 ? (w * 160 / d).round() : null;
    final dpH = h != null && d != null && d > 0 ? (h * 160 / d).round() : null;
    final sw = dpW != null && dpH != null ? min(dpW, dpH) : null;
    final fromInches = _physicalFromInches;
    final digits = [FilteringTextInputFormatter.digitsOnly];

    Widget field(TextEditingController c, String label, {double width = 92, List<TextInputFormatter>? fmt}) => SizedBox(
      width: width,
      child: TextField(
        controller: c,
        inputFormatters: fmt ?? digits,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _apply(),
      ),
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.aspect_ratio, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  phys == null ? 'Display' : 'Physical ${phys.w}×${phys.h} · ${_physicalDpi ?? '?'} dpi',
                  style: text.titleSmall,
                ),
              ),
              if (_overridden)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text('Override active', style: TextStyle(fontSize: 11, color: Colors.orange)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              field(_w, 'Width px'),
              const Text('×'),
              field(_h, 'Height px'),
              field(_dpi, 'DPI', width: 76),
              field(_inches, 'Screen inch', width: 100, fmt: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))]),
              IconButton(
                tooltip: 'Swap orientation',
                onPressed: () => setState(() {
                  final t = _w.text;
                  _w.text = _h.text;
                  _h.text = t;
                }),
                icon: const Icon(Icons.screen_rotation_alt, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              if (dpW != null && dpH != null) Text('Layout: $dpW×$dpH dp · sw${sw}dp', style: muted),
              if (sw != null) Text(_bucket(sw), style: muted),
              if (fromInches != null)
                InkWell(
                  onTap: () => setState(() => _dpi.text = '$fromInches'),
                  child: Text(
                    'Real panel ≈ $fromInches dpi — use it',
                    style: muted?.copyWith(color: scheme.primary, decoration: TextDecoration.underline),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('PRESETS', style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .6)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final p in displayPresets)
                Tooltip(
                  message: '${p.w}×${p.h} · ${p.dpi} dpi',
                  child: ActionChip(
                    label: Text(p.label),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _applyPreset(p),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy || w == null || h == null || d == null ? null : _apply,
                icon: _busy
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check, size: 18),
                label: const Text('Apply'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy || !_overridden ? null : _reset,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset to physical'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _bucket(int sw) => switch (sw) {
    < 360 => 'Small phone',
    < 600 => 'Phone',
    < 720 => 'Small tablet (sw600)',
    < 1000 => 'Tablet (sw720)',
    _ => 'Large screen / desktop',
  };
}
