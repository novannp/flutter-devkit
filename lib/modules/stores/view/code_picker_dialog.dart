import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../devices/services/device_adb.dart';
import '../models/store_code.dart';
import '../store_codes_cubit.dart';

/// Search a store, then type its activation/support code into the focused field on the device.
Future<String?> showCodePicker(BuildContext context, DeviceAdb dev) => showDialog<String>(
  context: context,
  builder: (_) => _CodePicker(dev: dev),
);

class _CodePicker extends StatefulWidget {
  const _CodePicker({required this.dev});

  final DeviceAdb dev;

  @override
  State<_CodePicker> createState() => _CodePickerState();
}

class _CodePickerState extends State<_CodePicker> {
  var _query = '';
  var _enter = false;

  Future<void> _type(String kind, String value) async {
    await widget.dev.text(value);
    if (_enter) await widget.dev.key('KEYCODE_ENTER');
    if (mounted) Navigator.pop(context, '$kind code typed on device');
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final codes = context
        .watch<StoreCodesCubit>()
        .state
        .where((c) => [c.storeName, c.activationCode, c.supportCode].any((v) => v.toLowerCase().contains(q)))
        .toList();
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Type code on device'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            const Text('Tap the code field on the device screen first, then pick a code below.'),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search stores…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            CheckboxListTile(
              value: _enter,
              onChanged: (v) => setState(() => _enter = v ?? false),
              title: const Text('Press Enter after typing'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            Expanded(
              child: codes.isEmpty
                  ? const Center(child: Text('No codes yet. Add some in "Store Codes".'))
                  : ListView.builder(
                      itemCount: codes.length,
                      itemBuilder: (_, i) {
                        final c = codes[i];
                        return ListTile(
                          title: Text(c.storeName),
                          subtitle: Text(c.env, style: TextStyle(color: scheme.outline)),
                          trailing: Wrap(
                            spacing: 6,
                            children: [
                              if (c.activationCode.isNotEmpty)
                                ActionChip(
                                  label: Text('Activation ${c.activationCode}'),
                                  onPressed: () => _type('Activation', c.activationCode),
                                ),
                              if (c.supportCode.isNotEmpty)
                                ActionChip(
                                  label: Text('Support ${c.supportCode}'),
                                  side: c.supportExpired ? const BorderSide(color: Colors.red) : null,
                                  tooltip: c.supportExpired ? 'Support code expired' : null,
                                  onPressed: () => _type('Support', c.supportCode),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    );
  }
}

String describeCode(StoreCode? store, String code) {
  if (store == null) return '$code · server ${StoreCode.serverOf(code)}${StoreCode.isTestCode(code) ? ' · test' : ''}';
  final kind = store.supportCode == code ? 'support' : 'activation';
  return '$code · ${store.storeName} ($kind)';
}
