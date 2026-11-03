import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'core/panels.dart';
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

const _undoActions = [
  ('Undo', Icons.undo, UndoTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyZ, false, 'Ctrl+Z'),
  ('Redo', Icons.redo, RedoTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyZ, true, 'Ctrl+Shift+Z'),
];

const _clipboardActions = [
  ('Cut', Icons.content_cut, CopySelectionTextIntent.cut(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyX, false, 'Ctrl+X'),
  ('Copy', Icons.content_copy, CopySelectionTextIntent.copy, LogicalKeyboardKey.keyC, false, 'Ctrl+C'),
  ('Paste', Icons.content_paste, PasteTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyV, false, 'Ctrl+V'),
  ('Select All', Icons.select_all, SelectAllTextIntent(SelectionChangedCause.keyboard), LogicalKeyboardKey.keyA, false, 'Ctrl+A'),
];

void invokeOnFocused(Intent intent) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused != null) Actions.maybeInvoke(focused, intent);
}

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text(konamiLine)));
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
    EditorCommands.openSettings = () => _go(_modules.indexOf(_settings));
    EditorCommands.windowCommands = () => [
      for (final m in _modules)
        if (m != _editor) PaletteItem('Open ${m.label}', () => _go(_modules.indexOf(m)), keys: m == _extensions ? 'Ctrl+Shift+X' : (m == _settings ? 'Ctrl+,' : null), icon: m.icon, group: 'Window'),
      PaletteItem('Getting Started', () => showGettingStarted(context), icon: Icons.school_outlined, group: 'Window'),
      PaletteItem('Connection Guide', () => showConnectionGuide(context), icon: Icons.help_outline, group: 'Window'),
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
    EditorCommands.openSettings = null;
    EditorCommands.windowCommands = null;
    ExtensionManager.instance.removeListener(_onExtensions);
    _tools.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _go(int i) {
    if (i < 0 || i >= _modules.length) return;
    _modules[i] == _editor ? _tools.showEditor() : _tools.show(_modules[i]);
  }

  void _onExtensions() {
    for (final e in builtinExtensions) {
      if (ExtensionManager.instance.isEnabled(e.id)) continue;
      e.modules.forEach(_tools.close);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: canvasOf(Theme.of(context).colorScheme),
      body: Column(
        children: [
          _TitleBar(active: _tools.active, onSelect: _go),
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
      ..showSnackBar(SnackBar(content: Text(pick(logoLines))));
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
  var _fullScreen = false;

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
    if (Platform.isMacOS) {
      windowManager.isFullScreen().then((v) {
        if (mounted) setState(() => _fullScreen = v);
      });
    }
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

  @override
  void onWindowEnterFullScreen() => setState(() => _fullScreen = true);

  @override
  void onWindowLeaveFullScreen() => setState(() => _fullScreen = false);

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
                leadingIcon: const Icon(Icons.folder_outlined, size: 16),
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
      _item('Settings', Icons.settings_outlined, () => _openModule(_settings), keys: 'Ctrl+,'),
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

  Widget _editMenu() => SubmenuButton(
    style: _itemStyle,
    menuChildren: [
      for (final (label, icon, intent, _, _, keys) in _undoActions) _item(label, icon, () => invokeOnFocused(intent), keys: keys),
      const Divider(height: 1),
      for (final (label, icon, intent, _, _, keys) in _clipboardActions) _item(label, icon, () => invokeOnFocused(intent), keys: keys),
    ],
    child: const Text('Edit'),
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
        const Text('A Flutter IDE with the device tools you test on right beside the code.'),
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

  PlatformMenuItem _nativeItem(String label, VoidCallback callback, {LogicalKeyboardKey? key, bool shift = false, bool control = false}) => PlatformMenuItem(
    label: label,
    onSelected: callback,
    shortcut: key == null ? null : SingleActivator(key, meta: !control, control: control, shift: shift),
  );

  PlatformMenuItem _editItem(String label, Intent intent, LogicalKeyboardKey key, {bool shift = false}) => PlatformMenuItem(
    label: label,
    shortcut: SingleActivator(key, meta: true, shift: shift),
    onSelected: () => invokeOnFocused(intent),
  );

  List<PlatformMenuItem> _nativeMenus() => [
    PlatformMenu(label: 'Flutter DevKit', menus: [
      _nativeItem('About Flutter DevKit', _about),
      PlatformMenuItemGroup(members: [
        _nativeItem('Settings…', () => _openModule(_settings), key: LogicalKeyboardKey.comma),
        PlatformMenu(label: 'Theme', menus: [
          for (final theme in appThemes)
            _nativeItem('${appTheme.value == theme ? '✓ ' : ''}${theme.name}', () => setAppTheme(theme)),
        ]),
      ]),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
      const PlatformMenuItemGroup(members: [
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
      ]),
      // Keep the save/cleanup path used by the in-app Quit command.
      _nativeItem('Quit Flutter DevKit', BackgroundRunner.instance.quit, key: LogicalKeyboardKey.keyQ),
    ]),
    PlatformMenu(label: 'File', menus: [
      _nativeItem('Open File…', () {
        _openModule(_editor);
        EditorCommands.openFile?.call();
      }, key: LogicalKeyboardKey.keyO),
      _nativeItem('Open Folder…', () {
        _openModule(_editor);
        EditorCommands.openFolder?.call();
      }),
      PlatformMenu(label: 'Open Recent', menus: [
        if (RecentPaths.paths.value.isEmpty) const PlatformMenuItem(label: 'Nothing yet'),
        for (final path in RecentPaths.paths.value)
          _nativeItem(path, () {
            _openModule(_editor);
            EditorCommands.openRecent?.call(path);
          }),
        if (RecentPaths.paths.value.isNotEmpty)
          PlatformMenuItemGroup(members: [_nativeItem('Clear Recently Opened', RecentPaths.clear)]),
      ]),
      PlatformMenuItemGroup(members: [
        _nativeItem('Go to File…', () {
          _openModule(_editor);
          EditorCommands.quickOpen?.call();
        }, key: LogicalKeyboardKey.keyP),
        _nativeItem('Save All', () => EditorCommands.saveAll?.call(), key: LogicalKeyboardKey.keyS, shift: true),
        _nativeItem('Command Palette', () => EditorCommands.commandPalette?.call(), key: LogicalKeyboardKey.keyP, shift: true),
        _nativeItem('Go to Symbol in File', () => EditorCommands.goToSymbol?.call(), key: LogicalKeyboardKey.keyO, shift: true),
        _nativeItem('Extensions', () => _openModule(_extensions), key: LogicalKeyboardKey.keyX, shift: true),
      ]),
    ]),
    PlatformMenu(label: 'Edit', menus: [
      PlatformMenuItemGroup(members: [
        for (final (label, _, intent, key, shift, _) in _undoActions) _editItem(label, intent, key, shift: shift),
      ]),
      for (final (label, _, intent, key, shift, _) in _clipboardActions) _editItem(label, intent, key, shift: shift),
    ]),
    for (final name in ['Device', 'Tools', 'Team'])
      if (name == 'Tools' || _enabledIn(name).isNotEmpty)
        PlatformMenu(label: name, menus: [
          if (name == 'Tools')
            _nativeItem('Terminal', () => EditorCommands.openTerminal?.call(), key: LogicalKeyboardKey.backquote, control: true),
          for (final module in _enabledIn(name)) _nativeItem(module.label, () => _openModule(module)),
        ]),
    const PlatformMenu(label: 'Window', menus: [
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
    ]),
    PlatformMenu(label: 'Help', menus: [
      _nativeItem('Getting started', () => showGettingStarted(context)),
      _nativeItem('Connection guide', () => showConnectionGuide(context)),
      _nativeItem('Show error log', () {
        final file = errorLogFile;
        if (file != null && file.existsSync()) unawaited(revealInExplorer(file.path));
      }),
      _nativeItem('Take a break 🎮', () => _takeABreak(context)),
    ]),
  ];

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
    final titleBar = Container(
      height: _barHeight,
      color: canvasOf(scheme),
      child: Stack(
        children: [
          Row(
            children: [
              // Reserve space for macOS window buttons only outside fullscreen.
              SizedBox(width: Platform.isMacOS && !_fullScreen ? 78 : 10),
              Tooltip(
                message: _tagline,
                child: _Logo(
                  onTap: () => _openModule(_editor),
                  child: const AppLogo(size: 20),
                ),
              ),
              const SizedBox(width: 6),
              if (!Platform.isMacOS) ListenableBuilder(
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
                      _editMenu(),
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
    if (!Platform.isMacOS) return titleBar;
    return ListenableBuilder(
      listenable: Listenable.merge([ExtensionManager.instance, RecentPaths.paths, appTheme]),
      builder: (_, child) => PlatformMenuBar(menus: _nativeMenus(), child: child),
      child: titleBar,
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
    ..showSnackBar(SnackBar(content: Text(installed ? pick(breakLines) : pick(noBreakLines))));
}
