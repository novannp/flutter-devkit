import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/app_logo.dart';
import 'core/background.dart';
import 'core/error_log.dart';
import 'core/files.dart';
import 'core/jokes.dart';
import 'core/theme.dart';
import 'extensions/registry.dart';
import 'modules/editor/editor_page.dart';
import 'modules/editor/editor_view.dart';
import 'modules/editor/tool_tabs.dart';
import 'modules/editor/palette.dart';
import 'modules/help/connection_guide.dart';
import 'modules/help/getting_started.dart';
import 'modules/settings/settings_page.dart';
import 'core/platform_keys.dart';

const _editor = AppModule('Editor', Icons.code, EditorPage());
const _settings = AppModule('Settings', Icons.settings_outlined, SettingsPage());
const _extensions = AppModule('Extensions', Icons.extension_outlined, ExtensionsPage());

/// Each page keeps its place here, so turning an extension off doesn't shift the others.
final _modules = [
  _editor,
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(showGettingStartedOnce(context));
    });
    EditorCommands.openExtensions = () => _go(_modules.indexOf(_extensions));
    EditorCommands.windowCommands = () => [
      for (final m in _modules)
        if (m != _editor) PaletteItem('Open ${m.label}', () => _go(_modules.indexOf(m)), keys: m == _extensions ? 'Ctrl+Shift+X' : null, icon: m.icon),
      PaletteItem('Getting Started', () => showGettingStarted(context), icon: Icons.school_outlined),
      PaletteItem('Connection Guide', () => showConnectionGuide(context), icon: Icons.help_outline),
    ];
    ExtensionManager.instance.addListener(_onExtensions);
    _tools.addListener(_rebuild);
    BackgroundRunner.instance.onQuit = () async {
      await editorSaveAllOnQuit?.call();
    };
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    EditorCommands.openExtensions = null;
    EditorCommands.windowCommands = null;
    ExtensionManager.instance.removeListener(_onExtensions);
    _tools.removeListener(_rebuild);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TitleBar(active: _tools.active, onSelect: _go),
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

/// Not every tab is one of the modules: a diff opens as a tab of its own.
String windowTitleFor(AppModule? active) => active == null || active == _editor ? 'Flutter DevKit' : '${active.label} — Flutter DevKit';

const _barHeight = 30.0;
const _menusFoldBelow = 640.0;

class _TitleBar extends StatefulWidget {
  const _TitleBar({required this.active, required this.onSelect});

  final AppModule? active;
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

  void _openModule(AppModule m) => widget.onSelect(_modules.indexOf(m));

  Widget _item(String label, IconData icon, VoidCallback? onPressed, {String? keys, Widget? trailing}) => MenuItemButton(
    style: _itemStyle,
    leadingIcon: Icon(icon, size: 17),
    onPressed: onPressed,
    trailingIcon: keys == null ? null : Text(platformKeys(keys), style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
    child: trailing ?? Text(label),
  );

  Widget _moduleItem(AppModule m) => _item(m.label, m.icon, () => _openModule(m));

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
      _item('Command Palette', Icons.keyboard_command_key, () => EditorCommands.commandPalette?.call(), keys: 'Ctrl+Shift+P'),
      _item('Go to Symbol in File', Icons.data_object, () => EditorCommands.goToSymbol?.call(), keys: 'Ctrl+Shift+O'),
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
      _item('Quit Flutter DevKit (the bugs will wait)', Icons.power_settings_new, BackgroundRunner.instance.quit),
    ],
    child: const Text('File'),
  );

  Widget? _menu(String title, List<AppModule> modules, {List<Widget> first = const []}) {
    if (modules.isEmpty && first.isEmpty) return null;
    return SubmenuButton(
      style: _itemStyle,
      menuChildren: [...first, for (final m in modules) _moduleItem(m)],
      child: Text(title),
    );
  }

  void _about() {
    final scheme = Theme.of(context).colorScheme;
    showAboutDialog(
      context: context,
      applicationName: 'Flutter DevKit',
      applicationVersion: 'Version $appVersion',
      applicationIcon: const AppLogo(size: 48),
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
      _item('Getting started', Icons.school_outlined, () => showGettingStarted(context)),
      _item('Connection guide', Icons.help_outline, () => showConnectionGuide(context)),
      _item('Show error log', Icons.description_outlined, () {
        final file = errorLogFile;
        if (file != null && file.existsSync()) unawaited(revealInExplorer(file.path));
      }),
      _item('Take a break 🎮', Icons.sports_esports_outlined, () => _takeABreak(context)),
      const Divider(height: 1),
      _item('About Flutter DevKit', Icons.info_outline, _about),
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
              // macOS draws its window buttons here.
              SizedBox(width: Platform.isMacOS ? 78 : 10),
              Tooltip(
                message: _tagline,
                child: _Logo(
                  onTap: () => _openModule(_editor),
                  child: const AppLogo(size: 20),
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
                      ?_menu(
                        'Tools',
                        _enabledIn('Tools'),
                        first: [_item('Terminal', Icons.terminal, () => EditorCommands.openTerminal?.call(), keys: 'Ctrl+`')],
                      ),
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
                        windowTitleFor(widget.active),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ),
                ),
              ),
              if (!Platform.isMacOS) ...[
              _CaptionButton(icon: Icons.remove, tooltip: 'Minimize', onPressed: windowManager.minimize),
              _CaptionButton(
                icon: _maximized ? Icons.filter_none : Icons.crop_square,
                iconSize: _maximized ? 13 : 15,
                tooltip: _maximized ? 'Restore' : 'Maximize',
                onPressed: _maximized ? windowManager.unmaximize : windowManager.maximize,
              ),
              _CaptionButton(icon: Icons.close, tooltip: 'Close', danger: true, onPressed: windowManager.close),
              ],
            ],
          ),
          if (!_maximized && !Platform.isMacOS) ...[
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
  final installed = Platform.isMacOS
      ? Directory('/Applications/Steam.app').existsSync()
      : (await Process.run('reg', ['query', r'HKCU\Software\Valve\Steam', '/v', 'SteamExe'])).exitCode == 0;
  if (installed) await openExternal('steam://open/main');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(width: 420, content: Text(installed ? pick(breakLines) : pick(noBreakLines))));
}
