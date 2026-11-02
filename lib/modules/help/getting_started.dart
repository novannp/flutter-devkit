import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/platform_keys.dart';

const _seenKey = 'getting_started_seen';

const _steps = [
  (
    Icons.folder_open,
    'Open a project',
    [
      ('File → Open Folder', 'or pick a project on the start page. Each open project gets its own tab.'),
      ('File → Open Recent', 'brings back a folder, along with the files you had open.'),
      ('Nothing to set up', 'analysis uses the project\'s own Flutter SDK, including one pinned by fvm.'),
    ],
  ),
  (
    Icons.edit_note,
    'Write code',
    [
      ('Ctrl+Shift+P', 'finds any command, so you never need to remember a shortcut.'),
      ('Ctrl+P', 'finds a file. Words can come in any order, so "online payment" finds online_payment.'),
      ('Ctrl+Space', 'suggests code. Type stless or stful and press Enter for a widget, then Tab between its fields.'),
      ('Ctrl+click', 'goes to a definition. On a declaration it lists every usage.'),
      ('Ctrl+D', 'selects the word, then adds a cursor at each next match.'),
    ],
  ),
  (
    Icons.play_arrow,
    'Run your app',
    [
      ('Device picker', 'in the toolbar chooses where to run. It can also start an emulator, normally or with a cold boot.'),
      ('F5', 'runs the app. Shift+F5 stops it.'),
      ('Ctrl+F5', 'hot reloads. Ctrl+Shift+F5 hot restarts.'),
    ],
  ),
  (
    Icons.bug_report_outlined,
    'Debug and commit',
    [
      ('F9', 'sets a breakpoint. Ctrl+Shift+D opens the debug panel with variables and the call stack.'),
      ('F10 / F11', 'step over and into.'),
      ('Ctrl+Shift+G', 'opens Source Control: stage and commit, or click a file to compare before and after.'),
    ],
  ),
  (
    Icons.tune,
    'Make it yours',
    [
      ('Device menu', 'has mirroring, logs, and file and APK tools for your phones.'),
      ('Ctrl+Shift+X', 'turns the built-in extensions on or off, such as Printer, Notes and Work.'),
      ('File menu', 'has the themes and the Dart settings, such as line length.'),
      ('Help menu', 'brings this guide back, and explains how to connect a phone.'),
    ],
  ),
];

Future<void> showGettingStarted(BuildContext context) => showDialog<void>(context: context, builder: (_) => const GettingStartedDialog());

/// Once per install, so the guide doesn't get in the way afterwards.
Future<void> showGettingStartedOnce(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_seenKey) ?? false) return;
  await prefs.setBool(_seenKey, true);
  if (context.mounted) await showGettingStarted(context);
}

class GettingStartedDialog extends StatefulWidget {
  const GettingStartedDialog({super.key});

  @override
  State<GettingStartedDialog> createState() => _GettingStartedDialogState();
}

class _GettingStartedDialogState extends State<GettingStartedDialog> {
  var _index = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, title, rows) = _steps[_index];
    final last = _index == _steps.length - 1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Getting started · ${_index + 1} of ${_steps.length}', style: TextStyle(fontSize: 12, color: scheme.outline)),
              const SizedBox(height: 12),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 140),
                  child: SingleChildScrollView(
                    key: ValueKey(_index),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(icon, color: scheme.primary),
                            const SizedBox(width: 10),
                            Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                          ],
                        ),
                        const SizedBox(height: 14),
                        for (final (name, text) in rows)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: platformKeys(name), style: const TextStyle(fontWeight: FontWeight.w600)),
                                  TextSpan(text: name == 'Nothing to set up' ? ': $text' : ' ${platformKeys(text)}'),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (!last) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
                  const Spacer(),
                  if (_index > 0) TextButton(onPressed: () => setState(() => _index--), child: const Text('Back')),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: last ? () => Navigator.pop(context) : () => setState(() => _index++),
                    child: Text(last ? 'Start coding' : 'Next'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
