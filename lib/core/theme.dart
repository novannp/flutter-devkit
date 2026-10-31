import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _prefTheme = 'theme_mode';
const brandColor = Color(0xFF10B981);

final themeMode = ValueNotifier(ThemeMode.light);

Future<void> loadThemeMode() async {
  final saved = (await SharedPreferences.getInstance()).getString(_prefTheme);
  themeMode.value = ThemeMode.values.where((m) => m.name == saved).firstOrNull ?? ThemeMode.light;
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeMode.value = mode;
  await (await SharedPreferences.getInstance()).setString(_prefTheme, mode.name);
}

ThemeData buildTheme(Brightness brightness) {
  final light = brightness == Brightness.light;
  final scheme = ColorScheme.fromSeed(
    seedColor: brandColor,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(
    primary: light ? const Color(0xFF059669) : const Color(0xFF34D399),
    surface: light ? Colors.white : const Color(0xFF15181D),
    surfaceContainerLowest: light ? const Color(0xFFFAFBFC) : const Color(0xFF0E1013),
    surfaceContainerLow: light ? const Color(0xFFF6F7F9) : const Color(0xFF1A1D23),
    surfaceContainer: light ? const Color(0xFFF1F3F5) : const Color(0xFF1F232A),
    surfaceContainerHigh: light ? const Color(0xFFEBEEF1) : const Color(0xFF262B33),
    outline: light ? const Color(0xFF6B7280) : const Color(0xFF9CA3AF),
    outlineVariant: light ? const Color(0xFFE5E7EB) : const Color(0xFF2E333B),
  );
  final radius = BorderRadius.circular(10);
  final border = OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: scheme.outlineVariant));

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Segoe UI',
    scaffoldBackgroundColor: light ? const Color(0xFFF6F7F9) : const Color(0xFF101216),
    dividerColor: scheme.outlineVariant,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: scheme.outlineVariant)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      isDense: true,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        foregroundColor: scheme.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
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
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: scheme.outlineVariant)),
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
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : null),
    ),
    listTileTheme: const ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10)))),
    textTheme: Typography.material2021(platform: TargetPlatform.windows)
        .englishLike
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
      titleTextStyle: TextStyle(fontFamily: 'Segoe UI', fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
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
          RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: scheme.outlineVariant)),
        ),
      ),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: scheme.primary, textColor: scheme.onPrimary),
  );
}
