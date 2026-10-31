import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../devices/cubit/devices_cubit.dart';
import '../../devices/models/device.dart';
import '../../devices/services/adb_service.dart';
import '../../devices/services/device_adb.dart';
import '../models/store_code.dart';
import '../store_codes_cubit.dart';
import 'store_code_dialog.dart';

class StoresPage extends StatefulWidget {
  const StoresPage({super.key});

  @override
  State<StoresPage> createState() => _StoresPageState();
}

class _StoresPageState extends State<StoresPage> {
  var _query = '';
  String? _env;

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating, width: 420));

  Future<void> _add() async {
    final code = await showStoreCodeDialog(context);
    if (code != null && mounted) context.read<StoreCodesCubit>().upsert(code);
  }

  Future<void> _export() async {
    final loc = await getSaveLocation(suggestedName: 'store_codes.json', acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ]);
    if (loc == null || !mounted) return;
    await context.read<StoreCodesCubit>().exportTo(loc.path);
    _toast('Exported to ${loc.path}');
  }

  Future<void> _import() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ]);
    if (file == null || !mounted) return;
    try {
      final n = await context.read<StoreCodesCubit>().importFrom(file.path);
      _toast('Imported $n stores');
    } catch (e) {
      _toast('Invalid file: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return BlocBuilder<StoreCodesCubit, List<StoreCode>>(
      builder: (context, codes) {
        final q = _query.toLowerCase();
        final visible = codes
            .where((c) => _env == null || c.env == _env)
            .where((c) => [c.storeName, c.activationCode, c.supportCode, c.devicePrefix, c.notes]
                .any((v) => v.toLowerCase().contains(q)))
            .toList();

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('Store Codes', style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Text('${codes.length} stores', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                  const Spacer(),
                  TextButton.icon(onPressed: _import, icon: const Icon(Icons.file_open_outlined), label: const Text('Import')),
                  TextButton.icon(onPressed: _export, icon: const Icon(Icons.ios_share), label: const Text('Export')),
                  const SizedBox(width: 8),
                  FilledButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add store')),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  SizedBox(
                    width: 360,
                    child: TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search store, code, prefix…',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  for (final e in [null, ...storeEnvs])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(e ?? 'All'),
                        selected: _env == e,
                        onSelected: (_) => setState(() => _env = e),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: visible.isEmpty
                    ? _Empty(hasData: codes.isNotEmpty, onAdd: _add, onImport: _import)
                    : ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) => _StoreRow(code: visible[i], toast: _toast),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StoreRow extends StatelessWidget {
  const _StoreRow({required this.code, required this.toast});

  final StoreCode code;
  final void Function(String) toast;

  @override
  Widget build(BuildContext context) {
    final c = code;
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.outline, fontSize: 12);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.storeName,
                          style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    _Tag(text: c.env, color: c.env == 'prod' ? Colors.red : Colors.teal),
                  ],
                ),
                if (c.notes.isNotEmpty) Text(c.notes, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: _CodeCell(
              label: 'Activation',
              value: c.activationCode,
              hint: c.activationCode.isEmpty
                  ? null
                  : 'Server ${c.server}${StoreCode.isTestCode(c.activationCode) ? ' · test' : ''}'
                      '${c.devicePrefix.isNotEmpty ? ' · prefix ${c.devicePrefix}' : ''}',
              toast: toast,
            ),
          ),
          Expanded(
            flex: 3,
            child: _CodeCell(
              label: 'Support',
              value: c.supportCode,
              hint: _expireText(c),
              hintColor: c.supportExpired ? Colors.red : null,
              toast: toast,
            ),
          ),
          _TypeToDeviceButton(code: c, toast: toast),
          PopupMenuButton<String>(
            onSelected: (v) async {
              final cubit = context.read<StoreCodesCubit>();
              if (v == 'edit') {
                final updated = await showStoreCodeDialog(context, initial: c);
                if (updated != null) cubit.upsert(updated);
              } else if (v == 'delete') {
                cubit.remove(c);
                toast('${c.storeName} deleted');
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  String? _expireText(StoreCode c) {
    final exp = c.supportExpire;
    if (c.supportCode.isEmpty || exp == null) return null;
    final days = exp.difference(DateTime.now()).inDays;
    if (c.supportExpired) return 'Expired ${exp.day}/${exp.month}/${exp.year}';
    return days == 0 ? 'Expires today' : 'Expires in $days days';
  }
}

class _CodeCell extends StatelessWidget {
  const _CodeCell({required this.label, required this.value, required this.toast, this.hint, this.hintColor});

  final String label;
  final String value;
  final String? hint;
  final Color? hintColor;
  final void Function(String) toast;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (value.isEmpty) return Text('$label: -', style: TextStyle(color: scheme.outline));
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        Clipboard.setData(ClipboardData(text: value));
        toast('$label code copied');
      },
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('$label  ', style: TextStyle(color: scheme.outline, fontSize: 12)),
                Text(value, style: const TextStyle(fontFamily: 'Consolas', fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(width: 6),
                Icon(Icons.copy, size: 14, color: scheme.outline),
              ],
            ),
            if (hint != null) Text(hint!, style: TextStyle(fontSize: 12, color: hintColor ?? scheme.outline)),
          ],
        ),
      ),
    );
  }
}

/// Types the code straight into the focused field on the device.
class _TypeToDeviceButton extends StatelessWidget {
  const _TypeToDeviceButton({required this.code, required this.toast});

  final StoreCode code;
  final void Function(String) toast;

  @override
  Widget build(BuildContext context) {
    final devices = context
        .watch<DevicesCubit>()
        .state
        .devices
        .where((d) => d.adb == AdbState.connected && d.adbTarget != null)
        .toList();
    final kinds = [
      if (code.activationCode.isNotEmpty) ('Activation', code.activationCode),
      if (code.supportCode.isNotEmpty) ('Support', code.supportCode),
    ];

    return PopupMenuButton<(Device, String, String)>(
      tooltip: 'Type on device',
      enabled: kinds.isNotEmpty,
      icon: const Icon(Icons.keyboard_alt_outlined),
      onSelected: (sel) async {
        final (device, kind, value) = sel;
        await DeviceAdb(context.read<AdbService>(), device.adbTarget!).text(value);
        toast('$kind code typed on ${device.displayName}');
      },
      itemBuilder: (_) => devices.isEmpty
          ? [const PopupMenuItem(enabled: false, child: Text('No ADB device connected'))]
          : [
              for (final d in devices)
                for (final (kind, value) in kinds)
                  PopupMenuItem(value: (d, kind, value), child: Text('${d.displayName}  ←  $kind')),
            ],
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
        child: Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.hasData, required this.onAdd, required this.onImport});

  final bool hasData;
  final VoidCallback onAdd;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    if (hasData) return const Center(child: Text('No matching stores'));
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storefront_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text('No store codes yet', style: Theme.of(context).textTheme.titleMedium),
          const Text('Add one manually, or import a JSON file from a teammate.'),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(onPressed: onImport, child: const Text('Import')),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAdd, child: const Text('Add store')),
            ],
          ),
        ],
      ),
    );
  }
}
