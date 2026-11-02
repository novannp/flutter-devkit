import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/background.dart';
import 'core/jokes.dart';
import 'core/theme.dart';
import 'extensions/chat/chat_notifier.dart';
import 'extensions/registry.dart';
import 'extensions/chat/chat_page.dart';
import 'extensions/chat/chat_service.dart';
import 'modules/console/console_page.dart';
import 'modules/editor/editor_page.dart';
import 'modules/editor/editor_view.dart';
import 'modules/editor/tool_tabs.dart';
import 'modules/help/connection_guide.dart';
import 'modules/settings/settings_page.dart';

const _editor = AppModule('Editor', Icons.code, EditorPage());
const _terminal = AppModule('Terminal', Icons.terminal, ConsolePage());
const _settings = AppModule('Settings', Icons.settings_outlined, SettingsPage());
const _extensions = AppModule('Extensions', Icons.extension_outlined, ExtensionsPage());

/// Each page keeps its place here, so turning an extension off doesn't shift the others.
final _modules = [
  _editor,
  _terminal,
  _settings,
  _extensions,
  for (final e in builtinExtensions) ...e.modules,
];

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  StreamSubscription<ChatMessage>? _chatSub;

  static final _chatIndex = _modules.indexWhere((m) => m.page is ChatPage);

  ToolTabs get _tools => ToolTabs.instance;

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
    EditorCommands.openExtensions = () => _go(_modules.indexOf(_extensions));
    ExtensionManager.instance.addListener(_onExtensions);
    _tools.addListener(_rebuild);
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
    EditorCommands.openExtensions = null;
    ExtensionManager.instance.removeListener(_onExtensions);
    _tools.removeListener(_rebuild);
    _chatSub?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _go(int i) => _modules[i] == _editor ? _tools.showEditor() : _tools.show(_modules[i]);

  void _onExtensions() {
    for (final e in builtinExtensions) {
      if (ExtensionManager.instance.isEnabled(e.id)) continue;
      e.modules.forEach(_tools.close);
    }
  }

  Future<void> _openChat() async {
    await BackgroundRunner.instance.show();
    _go(_chatIndex);
  }

  Future<void> _onChat(ChatMessage m) async {
    final focused = await windowManager.isFocused() && !await windowManager.isMinimized();
    if (!focused) return ChatNotifier.show(m, onOpen: _openChat);
    if (_tools.active?.page is ChatPage || !mounted) return;
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
    if (!ExtensionManager.instance.isEnabled('chat')) return;
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
      body: Column(
        children: [
          _TitleBar(selected: _modules.indexOf(_tools.active ?? _editor), onSelect: _go),
          const Divider(height: 1),
          const Expanded(child: EditorPage()),
        ],
      ),
    );
  }
}

final _tagline = tagline();

class _Logo extends StatefulWidget {
  const _Logo({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Logo> createState() => _LogoState();
}

class _LogoState extends State<_Logo> {
  var _taps = 0;
  var _turns = 0.0;

  void _tap() {
    widget.onTap();
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

const _barHeight = 30.0;
const _menusFoldBelow = 640.0;

class _TitleBar extends StatefulWidget {
  const _TitleBar({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  State<_TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<_TitleBar> with WindowListener {
  var _maximized = false;

  static final _itemStyle = ButtonStyle(
    textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 13)),
    minimumSize: WidgetStateProperty.all(const Size(0, 28)),
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)),
    visualDensity: VisualDensity.compact,
  );

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _maximized = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  Widget _unread(Widget child) => ListenableBuilder(
    listenable: ChatService.instance,
    builder: (_, _) {
      final n = ChatService.instance.totalUnread;
      return n == 0 ? child : Badge(label: Text('$n'), child: child);
    },
  );

  void _openModule(AppModule m) => widget.onSelect(_modules.indexOf(m));

  Widget _item(String label, IconData icon, VoidCallback? onPressed, {String? keys, Widget? trailing}) => MenuItemButton(
    style: _itemStyle,
    leadingIcon: Icon(icon, size: 17),
    onPressed: onPressed,
    trailingIcon: keys == null ? null : Text(keys, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
    child: trailing ?? Text(label),
  );

  Widget _moduleItem(AppModule m) => _item(
    m.label,
    m.icon,
    () => _openModule(m),
    trailing: m.page is ChatPage ? _unread(Text(m.label)) : null,
  );

  List<AppModule> _enabledIn(String menu) => [
    for (final e in builtinExtensions)
      if (e.menu == menu && ExtensionManager.instance.isEnabled(e.id)) ...e.modules,
  ];

  Widget _fileMenu(ColorScheme scheme) => SubmenuButton(
    style: _itemStyle,
    menuChildren: [
      _item('Open File…', Icons.insert_drive_file_outlined, () {
        _openModule(_editor);
        EditorCommands.openFile?.call();
      }, keys: 'Ctrl+O'),
      _item('Open Folder…', Icons.folder_open_outlined, () {
        _openModule(_editor);
        EditorCommands.openFolder?.call();
      }),
      ValueListenableBuilder(
        valueListenable: RecentPaths.paths,
        builder: (_, recents, _) => SubmenuButton(
          style: _itemStyle,
          leadingIcon: const Icon(Icons.history, size: 17),
          menuChildren: [
            if (recents.isEmpty) _item('Nothing yet', Icons.history, null),
            for (final path in recents)
              MenuItemButton(
                style: _itemStyle,
                leadingIcon: Icon(p.extension(path).isEmpty ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16),
                onPressed: () {
                  _openModule(_editor);
                  EditorCommands.openRecent?.call(path);
                },
                child: Tooltip(
                  message: path,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Text.rich(
                      TextSpan(
                        text: p.basename(path),
                        children: [TextSpan(text: '   ${p.dirname(path)}', style: TextStyle(fontSize: 11.5, color: scheme.outline))],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            if (recents.isNotEmpty) ...[
              const Divider(height: 1),
              _item('Clear Recently Opened', Icons.clear_all, RecentPaths.clear),
            ],
          ],
          child: const Text('Open Recent'),
        ),
      ),
      const Divider(height: 1),
      _item('Go to File…', Icons.search, () {
        _openModule(_editor);
        EditorCommands.quickOpen?.call();
      }, keys: 'Ctrl+P'),
      _item('Save All', Icons.save_outlined, () => EditorCommands.saveAll?.call(), keys: 'Ctrl+Shift+S'),
      const Divider(height: 1),
      _item('Extensions', Icons.extension_outlined, () => _openModule(_extensions), keys: 'Ctrl+Shift+X'),
      _item('Settings', Icons.settings_outlined, () => _openModule(_settings)),
      SubmenuButton(
        style: _itemStyle,
        leadingIcon: const Icon(Icons.palette_outlined, size: 17),
        menuChildren: [
          for (final t in appThemes)
            ValueListenableBuilder(
              valueListenable: appTheme,
              builder: (_, current, _) => MenuItemButton(
                style: _itemStyle,
                closeOnActivate: false,
                leadingIcon: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: t.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: t.primary, width: 3),
                  ),
                ),
                trailingIcon: current == t ? Icon(Icons.check, size: 15, color: scheme.primary) : null,
                onPressed: () => setAppTheme(t),
                child: Text(t.name),
              ),
            ),
        ],
        child: const Text('Theme'),
      ),
      const Divider(height: 1),
      _item('Quit DevKit (the bugs will wait)', Icons.power_settings_new, BackgroundRunner.instance.quit),
    ],
    child: const Text('File'),
  );

  Widget? _menu(String title, List<AppModule> modules) {
    if (modules.isEmpty) return null;
    final label = Text(title);
    return SubmenuButton(
      style: _itemStyle,
      menuChildren: [for (final m in modules) _moduleItem(m)],
      child: modules.any((m) => m.page is ChatPage) ? _unread(label) : label,
    );
  }

  void _about() {
    final scheme = Theme.of(context).colorScheme;
    showAboutDialog(
      context: context,
      applicationName: 'DevKit',
      applicationVersion: 'Version $appVersion',
      applicationIcon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [scheme.primary, brandColor.withValues(alpha: .7)]),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.bolt_rounded, color: scheme.onPrimary, size: 28),
      ),
      children: [
        const Text('A Flutter IDE for Windows, with the device tools you test on right beside the code.'),
        const SizedBox(height: 10),
        Text('Dart ${Platform.version.split(' ').first}  •  ${Platform.operatingSystemVersion}', style: TextStyle(fontSize: 12, color: scheme.outline)),
      ],
    );
  }

  Widget _help() => SubmenuButton(
    style: _itemStyle,
    menuChildren: [
      _item('Connection guide', Icons.help_outline, () => showConnectionGuide(context)),
      _item('Take a break 🎮', Icons.sports_esports_outlined, () => _takeABreak(context)),
      const Divider(height: 1),
      _item('About DevKit', Icons.info_outline, _about),
    ],
    child: const Text('Help'),
  );

  // The native frame's top edge is gone along with its title bar; the other three sides still resize.
  Widget _resizeEdge(ResizeEdge edge, MouseCursor cursor) => MouseRegion(
    cursor: cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) => windowManager.startResizing(edge),
      child: const SizedBox.expand(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: _barHeight,
      color: scheme.surfaceContainerLow,
      child: Stack(
        children: [
          Row(
            children: [
              const SizedBox(width: 10),
              Tooltip(
                message: _tagline,
                child: _Logo(
                  onTap: () => _openModule(_editor),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [scheme.primary, brandColor.withValues(alpha: .7)]),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(Icons.bolt_rounded, color: scheme.onPrimary, size: 14),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ListenableBuilder(
                listenable: ExtensionManager.instance,
                builder: (_, _) => MenuBar(
                  style: MenuStyle(
                    backgroundColor: WidgetStateProperty.all(Colors.transparent),
                    elevation: WidgetStateProperty.all(0),
                    padding: WidgetStateProperty.all(EdgeInsets.zero),
                    shape: WidgetStateProperty.all(const RoundedRectangleBorder()),
                  ),
                  children: () {
                    final menus = [
                      _fileMenu(scheme),
                      ?_menu('Device', _enabledIn('Device')),
                      ?_menu('Tools', [_terminal, ..._enabledIn('Tools')]),
                      ?_menu('Team', _enabledIn('Team')),
                      _help(),
                    ];
                    if (MediaQuery.sizeOf(context).width >= _menusFoldBelow) return menus;
                    return <Widget>[
                      SubmenuButton(style: _itemStyle, menuChildren: menus, child: const Icon(Icons.menu, size: 17)),
                    ];
                  }(),
                ),
              ),
              Expanded(
                child: DragToMoveArea(
                  child: SizedBox.expand(
                    child: Center(
                      child: Text(
                        _modules[widget.selected] == _editor ? 'DevKit' : '${_modules[widget.selected].label} — DevKit',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ),
                ),
              ),
              _CaptionButton(icon: Icons.remove, tooltip: 'Minimize', onPressed: windowManager.minimize),
              _CaptionButton(
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                iconSize: _maximized ? 13 : 15,
                tooltip: _maximized ? 'Restore' : 'Maximize',
                onPressed: _maximized ? windowManager.unmaximize : windowManager.maximize,
              ),
              _CaptionButton(icon: Icons.close, tooltip: 'Close', danger: true, onPressed: windowManager.close),
            ],
          ),
          if (!_maximized) ...[
            Positioned(top: 0, left: 8, right: 8, height: 4, child: _resizeEdge(ResizeEdge.top, SystemMouseCursors.resizeUp)),
            Positioned(top: 0, left: 0, width: 8, height: 4, child: _resizeEdge(ResizeEdge.topLeft, SystemMouseCursors.resizeUpLeft)),
            Positioned(top: 0, right: 0, width: 8, height: 4, child: _resizeEdge(ResizeEdge.topRight, SystemMouseCursors.resizeUpRight)),
          ],
        ],
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.icon, required this.tooltip, required this.onPressed, this.iconSize = 16, this.danger = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 42,
            height: _barHeight,
            color: !_hover ? Colors.transparent : (widget.danger ? const Color(0xFFE81123) : scheme.onSurface.withValues(alpha: .08)),
            child: Icon(widget.icon, size: widget.iconSize, color: _hover && widget.danger ? Colors.white : scheme.onSurface),
          ),
        ),
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
