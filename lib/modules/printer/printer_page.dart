import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../core/clipboard_image.dart';
import '../../core/files.dart';
import '../help/connection_guide.dart';
import 'printer_server.dart';
import 'receipt_view.dart';

/// Single instance for the main window; the server keeps running across pages.
final printerServer = PrinterServer();

class PrinterPage extends StatefulWidget {
  const PrinterPage({super.key});

  @override
  State<PrinterPage> createState() => _PrinterPageState();
}

class _PrinterPageState extends State<PrinterPage> {
  final _paperKey = GlobalKey();
  Receipt? _selected;
  List<String> _ips = const [];
  var _showRaw = false;

  PrinterServer get s => printerServer;

  @override
  void initState() {
    super.initState();
    PrinterServer.localIps().then((ips) => mounted ? setState(() => _ips = ips) : null);
  }

  void _toast(String text, {SnackBarAction? action}) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action, width: 480));

  Future<String?> _renderPng() async {
    final boundary = _paperKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 2.5);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) return null;
    final path = '${(await outputDir()).path}${Platform.pathSeparator}receipt_${timestamp()}.png';
    await File(path).writeAsBytes(png.buffer.asUint8List());
    return path;
  }

  Future<void> _copyImage() async {
    final path = await _renderPng();
    if (path == null) return;
    final ok = await copyImageToClipboard(path);
    _toast(ok ? 'Receipt image copied — just Ctrl+V' : 'Saved: $path',
        action: SnackBarAction(label: 'Open folder', onPressed: () => revealInExplorer(path)));
  }

  String _hex(List<int> bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i += 16) {
      final row = bytes.skip(i).take(16).toList();
      sb.write(i.toRadixString(16).padLeft(6, '0'));
      sb.write('  ');
      sb.write(row.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').padRight(48));
      sb.write('  ');
      sb.writeln(row.map((b) => b >= 32 && b < 127 ? String.fromCharCode(b) : '.').join());
    }
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final selected = s.receipts.contains(_selected) ? _selected : s.receipts.firstOrNull;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Printer Emulator', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  _StatusPill(running: s.running, connections: s.activeConnections),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => showConnectionGuide(context, topic: GuideTopic.printer),
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: const Text('How to connect'),
                  ),
                  const Spacer(),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
                    selected: {s.paperMm},
                    onSelectionChanged: (v) => s.configure(paperMm: v.first),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: s.running ? s.sendSample : null,
                    icon: const Icon(Icons.science_outlined, size: 18),
                    label: const Text('Sample receipt'),
                  ),
                  const SizedBox(width: 8),
                  s.running
                      ? OutlinedButton.icon(onPressed: s.stop, icon: const Icon(Icons.stop, size: 18), label: const Text('Stop'))
                      : FilledButton.icon(onPressed: s.start, icon: const Icon(Icons.play_arrow, size: 18), label: const Text('Start')),
                ],
              ),
              const SizedBox(height: 12),
              _ConnectCard(ips: _ips, port: s.port, error: s.error, autoStart: s.autoStart, onPort: (p) => s.configure(port: p), onAuto: (v) => s.configure(autoStart: v)),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 300,
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: [
                            ListTile(
                              title: Text('Receipts (${s.receipts.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
                              trailing: IconButton(tooltip: 'Clear all', onPressed: s.receipts.isEmpty ? null : s.clear, icon: const Icon(Icons.delete_sweep_outlined)),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: s.receipts.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(20),
                                        child: Text('No receipts yet.\nPrint from the POS, or click "Sample receipt".',
                                            textAlign: TextAlign.center, style: TextStyle(color: scheme.outline)),
                                      ),
                                    )
                                  : ListView.builder(
                                      padding: const EdgeInsets.all(6),
                                      itemCount: s.receipts.length,
                                      itemBuilder: (_, i) {
                                        final r = s.receipts[i];
                                        final t = r.time;
                                        return ListTile(
                                          selected: r == selected,
                                          selectedTileColor: scheme.primary.withValues(alpha: 0.08),
                                          leading: const Icon(Icons.receipt_long_outlined),
                                          title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                          subtitle: Text(
                                            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')} · ${r.source} · ${(r.raw.length / 1024).toStringAsFixed(1)} KB',
                                            style: TextStyle(fontSize: 12, color: scheme.outline),
                                          ),
                                          onTap: () => setState(() => _selected = r),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Card(
                        margin: EdgeInsets.zero,
                        color: scheme.surfaceContainerLow,
                        child: selected == null
                            ? Center(child: Icon(Icons.print_outlined, size: 64, color: scheme.outlineVariant))
                            : Column(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
                                    child: Row(
                                      children: [
                                        FilterChip(label: const Text('Raw hex'), selected: _showRaw, onSelected: (v) => setState(() => _showRaw = v)),
                                        const Spacer(),
                                        TextButton.icon(
                                          onPressed: () {
                                            Clipboard.setData(ClipboardData(text: selected.text));
                                            _toast('Receipt text copied');
                                          },
                                          icon: const Icon(Icons.notes, size: 18),
                                          label: const Text('Copy text'),
                                        ),
                                        FilledButton.tonalIcon(
                                          onPressed: _copyImage,
                                          icon: const Icon(Icons.image_outlined, size: 18),
                                          label: const Text('Copy image'),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Expanded(
                                    child: _showRaw
                                        ? SingleChildScrollView(
                                            padding: const EdgeInsets.all(16),
                                            child: SelectableText(_hex(selected.raw), style: const TextStyle(fontFamily: 'Consolas', fontSize: 12.5)),
                                          )
                                        : SingleChildScrollView(
                                            padding: const EdgeInsets.symmetric(vertical: 24),
                                            child: Center(
                                              child: RepaintBoundary(
                                                key: _paperKey,
                                                child: Padding(
                                                  padding: const EdgeInsets.all(12),
                                                  child: ReceiptPaper(elements: selected.elements, paperMm: s.paperMm),
                                                ),
                                              ),
                                            ),
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
          ),
        );
      },
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.running, required this.connections});

  final bool running;
  final int connections;

  @override
  Widget build(BuildContext context) {
    final color = running ? const Color(0xFF059669) : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: color),
          const SizedBox(width: 6),
          Text(
            running ? (connections > 0 ? 'Receiving…' : 'Ready') : 'Stopped',
            style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  const _ConnectCard({
    required this.ips,
    required this.port,
    required this.error,
    required this.autoStart,
    required this.onPort,
    required this.onAuto,
  });

  final List<String> ips;
  final int port;
  final String? error;
  final bool autoStart;
  final ValueChanged<int> onPort;
  final ValueChanged<bool> onAuto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget code(String s) => InkWell(
          onTap: () => Clipboard.setData(ClipboardData(text: s)),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
            child: Text(s, style: const TextStyle(fontFamily: 'Consolas', fontWeight: FontWeight.w600)),
          ),
        );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (error != null) ...[
              Text(error!, style: TextStyle(color: scheme.error)),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Icon(Icons.lan_outlined, size: 18),
                const Text('In the POS printer settings, choose Network/LAN (ESC/POS: Hanasis, Volcora, SNBC) with IP:'),
                for (final ip in ips) code(ip),
                const Text('port'),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: '$port',
                    keyboardType: TextInputType.number,
                    onFieldSubmitted: (v) {
                      final p = int.tryParse(v);
                      if (p != null && p > 0 && p < 65536) onPort(p);
                    },
                  ),
                ),
                Text('· Android emulator: ', style: TextStyle(color: scheme.outline)),
                code('10.0.2.2'),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Auto-start'),
                    Switch(value: autoStart, onChanged: onAuto),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
