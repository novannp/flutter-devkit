import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'core/background.dart';
import 'core/jokes.dart';
import 'core/theme.dart';
import 'modules/chat/chat_notifier.dart';
import 'modules/chat/chat_page.dart';
import 'modules/chat/chat_service.dart';
import 'modules/console/console_page.dart';
import 'modules/devices/view/devices_page.dart';
import 'modules/devices/view/multi_screen_page.dart';
import 'modules/editor/editor_page.dart';
import 'modules/emulators/emulators_page.dart';
import 'modules/help/connection_guide.dart';
import 'modules/history/history_page.dart';
import 'modules/maintenance/maintenance_page.dart';
import 'modules/printer/printer_page.dart';
import 'modules/settings/settings_page.dart';
import 'modules/work/work_page.dart';

class _Module {
  const _Module(this.label, this.icon, this.page);

  final String label;
  final IconData icon;
  final Widget page;
}

class _Group {
  const _Group(this.title, this.modules);

  final String title;
  final List<_Module> modules;
}

const _groups = [
  _Group('Device', [
    _Module('Devices', Icons.devices_other, DevicesPage()),
    _Module('Multi Screen', Icons.grid_view_rounded, MultiScreenPage()),
    _Module('Emulators', Icons.phone_android_outlined, EmulatorsPage()),
  ]),
  _Group('Code', [_Module('Editor', Icons.code, EditorPage())]),
  _Group('Tools', [
    _Module('Terminal', Icons.terminal, ConsolePage()),
    _Module('Printer', Icons.receipt_long_outlined, PrinterPage()),
    _Module('Maintenance', Icons.cleaning_services_outlined, MaintenancePage()),
  ]),
  _Group('Team', [_Module('Work', Icons.task_alt, WorkPage()), _Module('Chat', Icons.forum_outlined, ChatPage())]),
  _Group('Other', [
    _Module('History', Icons.history, HistoryPage()),
    _Module('Settings', Icons.settings_outlined, SettingsPage()),
  ]),
];

final _modules = [for (final g in _groups) ...g.modules];

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  static final _startIndex = Platform.environment['DEVKIT_EDITOR'] == null
      ? 0
      : _modules.indexWhere((m) => m.page is EditorPage);
  late var _index = _startIndex;
  late final _visited = {_startIndex};
  StreamSubscription<ChatMessage>? _chatSub;

  static final _chatIndex = _modules.indexWhere((m) => m.page is ChatPage);

  static const _konami = [
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.keyB,
    LogicalKeyboardKey.keyA,
  ];
  var _konamiPos = 0;

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    _konamiPos = e.logicalKey == _konami[_konamiPos] ? _konamiPos + 1 : (e.logicalKey == _konami[0] ? 1 : 0);
    if (_konamiPos == _konami.length) {
      _konamiPos = 0;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(width: 460, content: Text(konamiLine)));
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _chatSub = ChatService.instance.incoming.stream.listen(_onChat);
    BackgroundRunner.instance.onQuit = () async {
      await editorSaveAllOnQuit?.call();
      await ChatService.instance.stop();
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _askNameIfNeeded());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _chatSub?.cancel();
    super.dispose();
  }

  void _go(int i) => setState(() => _visited.add(_index = i));

  Future<void> _openChat() async {
    await BackgroundRunner.instance.show();
    _go(_chatIndex);
  }

  Future<void> _onChat(ChatMessage m) async {
    final focused = await windowManager.isFocused() && !await windowManager.isMinimized();
    if (!focused) return ChatNotifier.show(m, onOpen: _openChat);
    if (_index == _chatIndex || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          width: 460,
          content: Text('${m.fromName}: ${m.text}', maxLines: 2, overflow: TextOverflow.ellipsis),
          action: SnackBarAction(label: 'Open', onPressed: () => _go(_chatIndex)),
        ),
      );
  }

  Future<void> _askNameIfNeeded() async {
    final chat = ChatService.instance;
    await chat.ready.future;
    if (chat.hasName || !mounted) return;
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _NameDialog(initial: chat.myName),
    );
    if (name != null) await chat.rename(name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _Sidebar(selected: _index, onSelect: _go),
          Expanded(
            // IndexedStack keeps page state (scans, logs, printer) alive when switching menus.
            child: IndexedStack(
              index: _index,
              children: [
                // Disabled TickerMode tells hidden pages to hide native windows (embedded scrcpy) too.
                // Built on first visit so e.g. Multi Screen doesn't start scrcpy at launch.
                for (final (i, m) in _modules.indexed)
                  TickerMode(enabled: i == _index, child: _visited.contains(i) ? m.page : const SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final _tagline = tagline();

class _Logo extends StatefulWidget {
  const _Logo({required this.child});

  final Widget child;

  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> {
  var _taps = 0;
  var _turns = 0.0;

  void _tap() {
    setState(() => _turns += 1);
    if (++_taps % 7 != 0) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(width: 420, content: Text(pick(logoLines))));
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: _tap,
    child: AnimatedRotation(turns: _turns, duration: const Duration(milliseconds: 500), child: widget.child),
  );
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    var i = 0;

    return Container(
      width: 208,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            child: Row(
              children: [
                _Logo(
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [scheme.primary, brandColor.withValues(alpha: .7)]),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(Icons.bolt_rounded, color: scheme.onPrimary, size: 20),
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('DevKit', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    Text(_tagline, style: text.labelSmall?.copyWith(color: scheme.outline)),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final g in _groups) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                    child: Text(
                      g.title.toUpperCase(),
                      style: text.labelSmall?.copyWith(color: scheme.outline, letterSpacing: .8),
                    ),
                  ),
                  for (final m in g.modules) _NavItem(module: m, index: i++, selected: selected, onSelect: onSelect),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
            child: TextButton.icon(
              onPressed: () => showConnectionGuide(context),
              icon: const Icon(Icons.help_outline, size: 18),
              label: const Text('Connection guide', maxLines: 1, overflow: TextOverflow.ellipsis),
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: 'Take a break 🎮',
                  onPressed: () => _takeABreak(context),
                  icon: const Icon(Icons.sports_esports_outlined, size: 20),
                ),
                IconButton(
                  tooltip: 'Quit DevKit (the bugs will wait)',
                  onPressed: BackgroundRunner.instance.quit,
                  icon: const Icon(Icons.power_settings_new, size: 20),
                ),
                ValueListenableBuilder(
                  valueListenable: themeMode,
                  builder: (_, mode, _) {
                    final dark = mode == ThemeMode.dark;
                    return IconButton(
                      tooltip: dark ? 'Light mode' : 'Dark mode',
                      onPressed: () => setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
                      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Easter egg: opens Steam for a well-earned break.
Future<void> _takeABreak(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final reg = await Process.run('reg', ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamExe']);
  final installed = reg.exitCode == 0;
  if (installed) await Process.run('explorer', ['steam://open/main']);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(width: 420, content: Text(installed ? pick(breakLines) : pick(noBreakLines))));
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.module, required this.index, required this.selected, required this.onSelect});

  final _Module module;
  final int index;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = index == selected;
    final color = active ? scheme.primary : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: active ? scheme.primary.withValues(alpha: .10) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onSelect(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(module.icon, size: 19, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    module.label,
                    style: TextStyle(color: color, fontWeight: active ? FontWeight.w600 : FontWeight.w500),
                  ),
                ),
                if (module.page is ChatPage)
                  ListenableBuilder(
                    listenable: ChatService.instance,
                    builder: (_, _) {
                      final n = ChatService.instance.totalUnread;
                      return n == 0 ? const SizedBox.shrink() : Badge(label: Text('$n'));
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  void _submit() {
    if (_ctrl.text.trim().length >= 2) Navigator.pop(context, _ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: const Text('Welcome to DevKit 👋'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('What should teammates call you? This name shows up in Chat.'),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Your name'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: _ctrl.text.trim().length >= 2 ? _submit : null, child: const Text('Continue'))],
    ),
  );
}
