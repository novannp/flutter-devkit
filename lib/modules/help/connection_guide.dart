import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../devices/view/pair_dialog.dart';

enum GuideTopic { usb, wireless, legacy, printer }

Future<void> showConnectionGuide(BuildContext context, {GuideTopic topic = GuideTopic.wireless}) =>
    showDialog<void>(context: context, builder: (_) => _GuideDialog(initial: topic));

class _GuideDialog extends StatefulWidget {
  const _GuideDialog({required this.initial});

  final GuideTopic initial;

  @override
  State<_GuideDialog> createState() => _GuideDialogState();
}

class _GuideDialogState extends State<_GuideDialog> {
  late var _topic = widget.initial;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 560,
        child: Row(
          children: [
            Container(
              width: 220,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 8, 8, 16),
                    child: Text('Connection guide', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                  for (final (t, icon, label) in [
                    (GuideTopic.wireless, Icons.wifi, 'Wi-Fi (Android 11+)'),
                    (GuideTopic.usb, Icons.usb, 'USB cable'),
                    (GuideTopic.legacy, Icons.router_outlined, 'Wi-Fi (older Android)'),
                    (GuideTopic.printer, Icons.print_outlined, 'Printer emulator'),
                  ])
                    ListTile(
                      selected: _topic == t,
                      selectedTileColor: scheme.primary.withValues(alpha: 0.10),
                      leading: Icon(icon, size: 20),
                      title: Text(label, style: const TextStyle(fontSize: 14)),
                      onTap: () => setState(() => _topic = t),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(28, 24, 28, 12), child: _content(context)),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) => switch (_topic) {
        GuideTopic.wireless => _Steps(
            title: 'Wireless debugging (Android 11+)',
            intro: 'Most convenient for devices at another desk. Pair once per phone per laptop.',
            steps: const [
              'Connect the phone and laptop to the same Wi-Fi.',
              'On the phone: Settings → About phone → tap "Build number" 7 times to enable Developer options.',
              'Developer options → turn on "Wireless debugging".',
              'If the device shows "Needs pairing" in DevKit (or doesn\'t show up at all), click "Pair device".',
              'On the phone: Wireless debugging → "Pair device with QR code", then scan the QR in DevKit. Or use "Pair device with pairing code" and enter the code.',
              'Done. DevKit will auto-connect whenever Wireless debugging is on, even if the port changes.',
            ],
            action: FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                showPairDialog(context);
              },
              icon: const Icon(Icons.qr_code_2),
              label: const Text('Open Pair device'),
            ),
            notes: const ['Office Wi-Fi that blocks device-to-device traffic (AP isolation) prevents devices from being detected.'],
          ),
        GuideTopic.usb => const _Steps(
            title: 'USB cable',
            intro: 'Most stable and fastest. Best for devices on your own desk.',
            steps: [
              'Enable Developer options (tap "Build number" 7 times).',
              'Developer options → turn on "USB debugging".',
              'Plug in a data cable (not a charge-only cable).',
              'When the phone shows "Allow USB debugging?" → check "Always allow from this computer" → Allow.',
              'The device appears in the Devices list within a few seconds.',
            ],
            notes: ['"Unauthorized" means the Allow USB debugging prompt on the phone hasn\'t been accepted yet.'],
          ),
        GuideTopic.legacy => _Steps(
            title: 'Wi-Fi for Android 10 and below (port 5555)',
            intro: 'For older devices without Wireless debugging. Needs a USB cable once to start.',
            steps: const [
              'Connect the device via USB first (see the USB guide).',
              'Run the command below once (e.g. from the Shell tab in the device workspace).',
              'Unplug the cable, then click "Scan network" in DevKit.',
            ],
            code: 'adb tcpip 5555',
            notes: const ['After the device restarts, run this command again.'],
          ),
        GuideTopic.printer => const _Steps(
            title: 'Printer emulator (paperless receipts)',
            intro: 'DevKit acts as a LAN thermal printer. Receipts printed by the POS show up in the Printer menu.',
            steps: [
              'Open the Printer menu in DevKit and make sure the status is "Ready".',
              'Note the laptop IP shown there (or 10.0.2.2 if the POS runs in the Android emulator).',
              'In the POS: Settings → Printer → add printer, choose Network/LAN connection with an ESC/POS brand (Hanasis, Volcora, or SNBC).',
              'Enter the laptop IP and port 9100, then save.',
              'Print a receipt from the POS; it appears in DevKit right away and can be copied as an image.',
            ],
            notes: [
              'Windows Firewall may prompt the first time; allow it for Private networks.',
              'Epson/Star printers use a proprietary protocol, so this emulator doesn\'t support them yet.',
            ],
          ),
      };
}

class _Steps extends StatelessWidget {
  const _Steps({required this.title, required this.intro, required this.steps, this.notes = const [], this.code, this.action});

  final String title;
  final String intro;
  final List<String> steps;
  final List<String> notes;
  final String? code;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(intro, style: TextStyle(color: scheme.outline)),
        const SizedBox(height: 20),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: Text('${i + 1}', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 13)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(steps[i]))),
              ],
            ),
          ),
        if (code != null)
          Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                Expanded(child: Text(code!, style: const TextStyle(fontFamily: 'Consolas', color: Colors.white))),
                IconButton(
                  tooltip: 'Copy',
                  onPressed: () => Clipboard.setData(ClipboardData(text: code!)),
                  icon: const Icon(Icons.copy, size: 16, color: Colors.white70),
                ),
              ],
            ),
          ),
        if (action != null) Padding(padding: const EdgeInsets.only(bottom: 14), child: action),
        for (final n in notes)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(8)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, size: 18, color: Color(0xFFB45309)),
                const SizedBox(width: 8),
                Expanded(child: Text(n, style: const TextStyle(color: Color(0xFF92400E), fontSize: 13))),
              ],
            ),
          ),
      ],
    );
  }
}
