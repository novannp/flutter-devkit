import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';

const _prefTheme = 'app_theme';
const _prefLegacyMode = 'theme_mode';
const brandColor = Color(0xFF10B981);

/// Same as `version` in pubspec.yaml; a test holds them together.
const appVersion = '1.0.0';

class SyntaxColors {
  const SyntaxColors({
    required this.type,
    required this.function,
    required this.variable,
    required this.enumMember,
    required this.keyword,
    required this.control,
    required this.string,
    required this.number,
    required this.comment,
  });

  final Color type, function, variable, enumMember, keyword, control, string, number, comment;
}

// Slipway's own colors, built around the emerald of its logo.
const _slipwayDark = SyntaxColors(
  type: Color(0xFF5EEAD4),
  function: Color(0xFF7DD3FC),
  variable: Color(0xFFE5E7EB),
  enumMember: Color(0xFFFCA5A5),
  keyword: Color(0xFF34D399),
  control: Color(0xFFC4B5FD),
  string: Color(0xFFFCD34D),
  number: Color(0xFFFB923C),
  comment: Color(0xFF7C8594),
);

const _slipwayLight = SyntaxColors(
  type: Color(0xFF0F766E),
  function: Color(0xFF0369A1),
  variable: Color(0xFF1F2937),
  enumMember: Color(0xFFB91C1C),
  keyword: Color(0xFF047857),
  control: Color(0xFF6D28D9),
  string: Color(0xFFB45309),
  number: Color(0xFFC2410C),
  comment: Color(0xFF6B7280),
);

const _vsCodeDark = SyntaxColors(
  type: Color(0xFF4EC9B0),
  function: Color(0xFFDCDCAA),
  variable: Color(0xFF9CDCFE),
  enumMember: Color(0xFF4FC1FF),
  keyword: Color(0xFF569CD6),
  control: Color(0xFFC586C0),
  string: Color(0xFFCE9178),
  number: Color(0xFFB5CEA8),
  comment: Color(0xFF6A9955),
);

const _vsCodeLight = SyntaxColors(
  type: Color(0xFF267F99),
  function: Color(0xFF795E26),
  variable: Color(0xFF001080),
  enumMember: Color(0xFF0070C1),
  keyword: Color(0xFF0000FF),
  control: Color(0xFFAF00DB),
  string: Color(0xFFA31515),
  number: Color(0xFF098658),
  comment: Color(0xFF008000),
);

class AppTheme {
  const AppTheme({
    required this.id,
    required this.name,
    required this.brightness,
    required this.primary,
    required this.background,
    required this.surface,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
    required this.outline,
    required this.outlineVariant,
    required this.syntax,
    this.text,
  });

  final String id, name;
  final Brightness brightness;
  final Color primary, background, surface, lowest, low, container, high, outline, outlineVariant;
  final Color? text;
  final SyntaxColors syntax;
}

// An id never changes, because it's what people's saved choice points at. A name can.
const appThemes = <AppTheme>[
  AppTheme(
    id: 'slipway-light',
    name: 'Slipway Light',
    brightness: Brightness.light,
    primary: Color(0xFF059669),
    background: Color(0xFFF6F7F9),
    surface: Colors.white,
    lowest: Color(0xFFFAFBFC),
    low: Color(0xFFF6F7F9),
    container: Color(0xFFF1F3F5),
    high: Color(0xFFEBEEF1),
    outline: Color(0xFF6B7280),
    outlineVariant: Color(0xFFE5E7EB),
    syntax: _slipwayLight,
  ),
  AppTheme(
    id: 'slipway-dark',
    name: 'Slipway Dark',
    brightness: Brightness.dark,
    primary: Color(0xFF34D399),
    background: Color(0xFF101216),
    surface: Color(0xFF15181D),
    lowest: Color(0xFF0E1013),
    low: Color(0xFF1A1D23),
    container: Color(0xFF1F232A),
    high: Color(0xFF262B33),
    outline: Color(0xFF9CA3AF),
    outlineVariant: Color(0xFF2E333B),
    syntax: _slipwayDark,
  ),
  AppTheme(
    id: 'dark-plus',
    name: 'VS Code Dark',
    brightness: Brightness.dark,
    primary: Color(0xFF3794FF),
    background: Color(0xFF1E1E1E),
    surface: Color(0xFF1E1E1E),
    lowest: Color(0xFF181818),
    low: Color(0xFF252526),
    container: Color(0xFF2D2D2D),
    high: Color(0xFF333333),
    outline: Color(0xFF9D9D9D),
    outlineVariant: Color(0xFF3C3C3C),
    text: Color(0xFFD4D4D4),
    syntax: _vsCodeDark,
  ),
  AppTheme(
    id: 'light-plus',
    name: 'VS Code Light',
    brightness: Brightness.light,
    primary: Color(0xFF0066B8),
    background: Color(0xFFF3F3F3),
    surface: Colors.white,
    lowest: Color(0xFFF8F8F8),
    low: Color(0xFFF3F3F3),
    container: Color(0xFFECECEC),
    high: Color(0xFFE4E4E4),
    outline: Color(0xFF6E6E6E),
    outlineVariant: Color(0xFFE0E0E0),
    text: Color(0xFF1F1F1F),
    syntax: _vsCodeLight,
  ),
  AppTheme(
    id: 'one-dark',
    name: 'One Dark',
    brightness: Brightness.dark,
    primary: Color(0xFF61AFEF),
    background: Color(0xFF21252B),
    surface: Color(0xFF282C34),
    lowest: Color(0xFF1D2025),
    low: Color(0xFF21252B),
    container: Color(0xFF2C313A),
    high: Color(0xFF353B45),
    outline: Color(0xFF8B92A0),
    outlineVariant: Color(0xFF3B4048),
    text: Color(0xFFABB2BF),
    syntax: SyntaxColors(
      type: Color(0xFFE5C07B),
      function: Color(0xFF61AFEF),
      variable: Color(0xFFE06C75),
      enumMember: Color(0xFFD19A66),
      keyword: Color(0xFFC678DD),
      control: Color(0xFFC678DD),
      string: Color(0xFF98C379),
      number: Color(0xFFD19A66),
      comment: Color(0xFF7F848E),
    ),
  ),
  AppTheme(
    id: 'dracula',
    name: 'Dracula',
    brightness: Brightness.dark,
    primary: Color(0xFFBD93F9),
    background: Color(0xFF21222C),
    surface: Color(0xFF282A36),
    lowest: Color(0xFF191A21),
    low: Color(0xFF21222C),
    container: Color(0xFF343746),
    high: Color(0xFF44475A),
    outline: Color(0xFF9AA3C7),
    outlineVariant: Color(0xFF44475A),
    text: Color(0xFFF8F8F2),
    syntax: SyntaxColors(
      type: Color(0xFF8BE9FD),
      function: Color(0xFF50FA7B),
      variable: Color(0xFFF8F8F2),
      enumMember: Color(0xFFBD93F9),
      keyword: Color(0xFFFF79C6),
      control: Color(0xFFFF79C6),
      string: Color(0xFFF1FA8C),
      number: Color(0xFFBD93F9),
      comment: Color(0xFF7D8BB8),
    ),
  ),
  AppTheme(
    id: 'monokai',
    name: 'Ember',
    brightness: Brightness.dark,
    primary: Color(0xFFA6E22E),
    background: Color(0xFF1E1F1C),
    surface: Color(0xFF272822),
    lowest: Color(0xFF1A1B18),
    low: Color(0xFF1E1F1C),
    container: Color(0xFF34352F),
    high: Color(0xFF3E3D32),
    outline: Color(0xFFA5A49B),
    outlineVariant: Color(0xFF3E3D32),
    text: Color(0xFFF8F8F2),
    syntax: SyntaxColors(
      type: Color(0xFF66D9EF),
      function: Color(0xFFA6E22E),
      variable: Color(0xFFF8F8F2),
      enumMember: Color(0xFFAE81FF),
      keyword: Color(0xFFF92672),
      control: Color(0xFFF92672),
      string: Color(0xFFE6DB74),
      number: Color(0xFFAE81FF),
      comment: Color(0xFF8E8A75),
    ),
  ),
  AppTheme(
    id: 'nord',
    name: 'Nord',
    brightness: Brightness.dark,
    primary: Color(0xFF88C0D0),
    background: Color(0xFF292E39),
    surface: Color(0xFF2E3440),
    lowest: Color(0xFF272C36),
    low: Color(0xFF292E39),
    container: Color(0xFF3B4252),
    high: Color(0xFF434C5E),
    outline: Color(0xFF9AA5B8),
    outlineVariant: Color(0xFF3B4252),
    text: Color(0xFFD8DEE9),
    syntax: SyntaxColors(
      type: Color(0xFF8FBCBB),
      function: Color(0xFF88C0D0),
      variable: Color(0xFFD8DEE9),
      enumMember: Color(0xFFB48EAD),
      keyword: Color(0xFF81A1C1),
      control: Color(0xFF81A1C1),
      string: Color(0xFFA3BE8C),
      number: Color(0xFFB48EAD),
      comment: Color(0xFF7B88A1),
    ),
  ),
  AppTheme(
    id: 'solarized-dark',
    name: 'Solarized Dark',
    brightness: Brightness.dark,
    primary: Color(0xFF2AA3E8),
    background: Color(0xFF00252F),
    surface: Color(0xFF002B36),
    lowest: Color(0xFF00212B),
    low: Color(0xFF00252F),
    container: Color(0xFF073642),
    high: Color(0xFF0A4352),
    outline: Color(0xFF93A1A1),
    outlineVariant: Color(0xFF0F4654),
    text: Color(0xFFB4C0C0),
    syntax: SyntaxColors(
      type: Color(0xFFB58900),
      function: Color(0xFF2AA3E8),
      variable: Color(0xFF9FB0B0),
      enumMember: Color(0xFF2AA198),
      keyword: Color(0xFF859900),
      control: Color(0xFF859900),
      string: Color(0xFF2AA198),
      number: Color(0xFFD33682),
      comment: Color(0xFF6F878F),
    ),
  ),
  AppTheme(
    id: 'solarized-light',
    name: 'Solarized Light',
    brightness: Brightness.light,
    primary: Color(0xFF1A6FA8),
    background: Color(0xFFEEE8D5),
    surface: Color(0xFFFDF6E3),
    lowest: Color(0xFFFBF1D9),
    low: Color(0xFFEEE8D5),
    container: Color(0xFFE9E2CE),
    high: Color(0xFFE4DCC5),
    outline: Color(0xFF657B83),
    outlineVariant: Color(0xFFDDD6C1),
    text: Color(0xFF475B62),
    syntax: SyntaxColors(
      type: Color(0xFF8A6A00),
      function: Color(0xFF1A6FA8),
      variable: Color(0xFF52666D),
      enumMember: Color(0xFF1E7F78),
      keyword: Color(0xFF6B7A00),
      control: Color(0xFF6B7A00),
      string: Color(0xFF1E7F78),
      number: Color(0xFFB02A6B),
      comment: Color(0xFF7D8F95),
    ),
  ),
  AppTheme(
    id: 'github-dark',
    name: 'Graphite',
    brightness: Brightness.dark,
    primary: Color(0xFF58A6FF),
    background: Color(0xFF010409),
    surface: Color(0xFF0D1117),
    lowest: Color(0xFF010409),
    low: Color(0xFF161B22),
    container: Color(0xFF21262D),
    high: Color(0xFF30363D),
    outline: Color(0xFF8B949E),
    outlineVariant: Color(0xFF30363D),
    text: Color(0xFFE6EDF3),
    syntax: SyntaxColors(
      type: Color(0xFFFFA657),
      function: Color(0xFFD2A8FF),
      variable: Color(0xFF79C0FF),
      enumMember: Color(0xFF79C0FF),
      keyword: Color(0xFFFF7B72),
      control: Color(0xFFFF7B72),
      string: Color(0xFFA5D6FF),
      number: Color(0xFF79C0FF),
      comment: Color(0xFF8B949E),
    ),
  ),
  AppTheme(
    id: 'github-light',
    name: 'Daylight',
    brightness: Brightness.light,
    primary: Color(0xFF0969DA),
    background: Color(0xFFF6F8FA),
    surface: Colors.white,
    lowest: Color(0xFFF6F8FA),
    low: Color(0xFFF6F8FA),
    container: Color(0xFFEFF2F5),
    high: Color(0xFFE7EBEF),
    outline: Color(0xFF656D76),
    outlineVariant: Color(0xFFD0D7DE),
    text: Color(0xFF1F2328),
    syntax: SyntaxColors(
      type: Color(0xFF953800),
      function: Color(0xFF8250DF),
      variable: Color(0xFF0550AE),
      enumMember: Color(0xFF0550AE),
      keyword: Color(0xFFCF222E),
      control: Color(0xFFCF222E),
      string: Color(0xFF0A3069),
      number: Color(0xFF0550AE),
      comment: Color(0xFF6E7781),
    ),
  ),
  AppTheme(
    id: 'high-contrast',
    name: 'High Contrast',
    brightness: Brightness.dark,
    primary: Color(0xFFFFB000),
    background: Colors.black,
    surface: Colors.black,
    lowest: Colors.black,
    low: Color(0xFF0A0A0A),
    container: Color(0xFF141414),
    high: Color(0xFF1F1F1F),
    outline: Color(0xFFC8C8C8),
    outlineVariant: Color(0xFF6FC3DF),
    text: Colors.white,
    syntax: _slipwayDark,
  ),
];

final appTheme = ValueNotifier(appThemes.first);

Future<void> loadAppTheme() async {
  final prefs = await SharedPreferences.getInstance();
  // Before themes there was only light or dark; keep whichever someone had picked.
  final id = prefs.getString(_prefTheme) ?? (prefs.getString(_prefLegacyMode) == 'dark' ? 'slipway-dark' : null);
  appTheme.value = appThemes.where((t) => t.id == id).firstOrNull ?? appThemes.first;
}

Future<void> setAppTheme(AppTheme theme) async {
  appTheme.value = theme;
  await (await SharedPreferences.getInstance()).setString(_prefTheme, theme.id);
  await Settings.instance.update('app.theme', theme.id);
}

ThemeData buildTheme(AppTheme t) {
  final brightness = t.brightness;
  final light = brightness == Brightness.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: t.primary,
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: t.primary,
        onPrimary: t.primary.computeLuminance() > .4 ? Colors.black : Colors.white,
        surface: t.surface,
        onSurface: t.text,
        onSurfaceVariant: t.text?.withValues(alpha: .8),
        surfaceContainerLowest: t.lowest,
        surfaceContainerLow: t.low,
        surfaceContainer: t.container,
        surfaceContainerHigh: t.high,
        outline: t.outline,
        outlineVariant: t.outlineVariant,
      );
  final radius = BorderRadius.circular(10);
  final border = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: scheme.outlineVariant),
  );

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: scheme.onSurface.withValues(alpha: .08),
    visualDensity: VisualDensity.compact,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: t.background,
    dividerColor: scheme.outlineVariant,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      isDense: true,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        foregroundColor: scheme.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 28),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        padding: const EdgeInsets.all(4),
        minimumSize: const Size(28, 28),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
        selectedBackgroundColor: scheme.primary.withValues(alpha: light ? 0.12 : 0.22),
        selectedForegroundColor: scheme.primary,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      side: BorderSide(color: scheme.outlineVariant),
      selectedColor: scheme.primary.withValues(alpha: light ? 0.12 : 0.22),
      backgroundColor: scheme.surface,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: light ? 0.12 : 0.22),
      selectedIconTheme: IconThemeData(color: scheme.primary),
      selectedLabelTextStyle: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600, fontSize: 12),
      unselectedLabelTextStyle: TextStyle(color: scheme.outline, fontSize: 12),
      unselectedIconTheme: IconThemeData(color: scheme.outline),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: const Color(0xFF1F2937), borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      waitDuration: const Duration(milliseconds: 400),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : null),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? scheme.primary : null,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      dense: true,
      minVerticalPadding: 4,
      contentPadding: EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
    ),
    textTheme: Typography.material2021(platform: TargetPlatform.windows).englishLike
        .merge(light ? Typography.blackMountainView : Typography.whiteMountainView)
        .copyWith(
          headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -.3),
          titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -.2),
          titleMedium: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          titleSmall: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          labelSmall: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        )
        .apply(fontFamily: 'Segoe UI', bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      titleTextStyle: TextStyle(
        fontFamily: 'Segoe UI',
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: scheme.primary,
      unselectedLabelColor: scheme.onSurfaceVariant,
      indicatorColor: scheme.primary,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: scheme.outlineVariant,
      labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
      overlayColor: WidgetStatePropertyAll(scheme.primary.withValues(alpha: .06)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(6),
      thumbColor: WidgetStatePropertyAll(scheme.outline.withValues(alpha: .35)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primary.withValues(alpha: .12),
      linearMinHeight: 3,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: scheme.primary, textColor: scheme.onPrimary),
  );
}

const _snackBarWidth = 420.0;

/// For MaterialApp.builder: floating snackbars sit bottom right, above the status bar.
/// The theme can only reach that through its insets, and those need the window's width.
Widget snackBarsBottomRight(BuildContext context, Widget? child) {
  final theme = Theme.of(context);
  final left = MediaQuery.sizeOf(context).width - _snackBarWidth - 16;
  return Theme(
    data: theme.copyWith(
      snackBarTheme: theme.snackBarTheme.copyWith(insetPadding: EdgeInsets.fromLTRB(left < 16 ? 16 : left, 8, 16, 32)),
    ),
    child: child ?? const SizedBox.shrink(),
  );
}
