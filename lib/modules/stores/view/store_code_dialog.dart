import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/store_code.dart';

const storeEnvs = ['prod', 'qa'];

Future<StoreCode?> showStoreCodeDialog(BuildContext context, {StoreCode? initial}) => showDialog<StoreCode>(
  context: context,
  builder: (_) => _StoreCodeDialog(initial: initial),
);

class _StoreCodeDialog extends StatefulWidget {
  const _StoreCodeDialog({this.initial});

  final StoreCode? initial;

  @override
  State<_StoreCodeDialog> createState() => _StoreCodeDialogState();
}

class _StoreCodeDialogState extends State<_StoreCodeDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.storeName);
  late final _activation = TextEditingController(text: widget.initial?.activationCode);
  late final _support = TextEditingController(text: widget.initial?.supportCode);
  late final _prefix = TextEditingController(text: widget.initial?.devicePrefix);
  late final _notes = TextEditingController(text: widget.initial?.notes);
  late var _env = widget.initial?.env ?? 'prod';
  late DateTime? _expire = widget.initial?.supportExpire;

  @override
  void initState() {
    super.initState();
    _activation.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    for (final c in [_name, _activation, _support, _prefix, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickExpire() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _expire ?? now.add(const Duration(days: 7)),
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 3)),
    );
    if (date != null) setState(() => _expire = DateTime(date.year, date.month, date.day, 23, 59));
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final base = widget.initial ?? StoreCode(id: DateTime.now().microsecondsSinceEpoch.toString(), storeName: '');
    Navigator.pop(
      context,
      base.copyWith(
        storeName: _name.text.trim(),
        env: _env,
        activationCode: _activation.text.trim(),
        supportCode: _support.text.trim(),
        supportExpire: _expire,
        clearSupportExpire: _expire == null,
        devicePrefix: _prefix.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final code = _activation.text.trim();
    final digits = [FilteringTextInputFormatter.digitsOnly];

    return AlertDialog(
      title: Text(widget.initial == null ? 'Add store' : 'Edit store'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Store name'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField(
                initialValue: _env,
                decoration: const InputDecoration(labelText: 'Environment'),
                // Older saved codes may still use a removed env; keep it selectable.
                items: [
                  for (final e in {...storeEnvs, _env}) DropdownMenuItem(value: e, child: Text(e)),
                ],
                onChanged: (v) => setState(() => _env = v!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _activation,
                inputFormatters: digits,
                decoration: InputDecoration(
                  labelText: 'Activation code',
                  helperText: code.isEmpty
                      ? null
                      : 'Server ${StoreCode.serverOf(code)}${StoreCode.isTestCode(code) ? ' · test code' : ''}',
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  return t.length == 7 || t.length == 9 ? null : 'Usually 7 or 9 digits';
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _support,
                      inputFormatters: digits,
                      decoration: const InputDecoration(labelText: 'Support code'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  TextButton.icon(
                    onPressed: _pickExpire,
                    icon: const Icon(Icons.event),
                    label: Text(_expire == null ? 'Expiry?' : '${_expire!.day}/${_expire!.month}/${_expire!.year}'),
                  ),
                  if (_expire != null)
                    IconButton(
                      tooltip: 'Clear date',
                      onPressed: () => setState(() => _expire = null),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _prefix,
                decoration: const InputDecoration(labelText: 'Device prefix (optional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Notes (optional)'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
