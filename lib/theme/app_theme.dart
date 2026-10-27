import 'package:flutter/material.dart';

/// App 自己的语义色。
///
/// 「支出是红的、收入是绿的」这件事以前是直接写死 `Colors.red` / `Colors.green`，
/// 在深色模式下这套颜色又刺眼又瞎——红绿本身在暗背景上就很难区分。
///
/// 所以把它们收进主题扩展里：
/// - 明暗两套色值；
/// - 跟着 [ThemeData] 一起插值（切换主题时不会突变）；
/// - 分类色在暗色下自动提亮。
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.expense,
    required this.income,
    required this.expenseContainer,
    required this.incomeContainer,
    required this.neutralContainer,
  });

  final Brightness brightness;

  /// 支出金额、支出小计。
  final Color expense;

  /// 收入金额、收入小计。
  final Color income;

  /// 支出的浅色底（chip、图标圆底）。
  final Color expenseContainer;

  /// 收入的浅色底。
  final Color incomeContainer;

  /// 中性容器色（搜索框、chip 底）。
  final Color neutralContainer;

  @override
  AppColors copyWith({
    Brightness? brightness,
    Color? expense,
    Color? income,
    Color? expenseContainer,
    Color? incomeContainer,
    Color? neutralContainer,
  }) {
    return AppColors(
      brightness: brightness ?? this.brightness,
      expense: expense ?? this.expense,
      income: income ?? this.income,
      expenseContainer: expenseContainer ?? this.expenseContainer,
      incomeContainer: incomeContainer ?? this.incomeContainer,
      neutralContainer: neutralContainer ?? this.neutralContainer,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      expense: Color.lerp(expense, other.expense, t)!,
      income: Color.lerp(income, other.income, t)!,
      expenseContainer: Color.lerp(expenseContainer, other.expenseContainer, t)!,
      incomeContainer: Color.lerp(incomeContainer, other.incomeContainer, t)!,
      neutralContainer: Color.lerp(neutralContainer, other.neutralContainer, t)!,
    );
  }

  /// 分类色在深色主题下要提亮。
  ///
  /// 分类色表是固定的一套（用户靠颜色认分类），但那套色值是给白底设计的，
  /// 直接搬到黑底上会糊成一团看不清。
  Color categoryColor(Color base) {
    if (brightness != Brightness.dark) return base;
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withLightness((hsl.lightness + 0.24).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation * 0.88).clamp(0.0, 1.0))
        .toColor();
  }
}

/// 取主题的快捷方式。
extension AppThemeX on BuildContext {
  ThemeData get theme => Theme.of(this);

  ColorScheme get scheme => Theme.of(this).colorScheme;

  /// App 的语义色。主题一定带着这个扩展，拿不到就退回默认配色。
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ??
      const AppColors(
        brightness: Brightness.light,
        expense: Color(0xFFD8433A),
        income: Color(0xFF1E8E4E),
        expenseContainer: Color(0xFFFFEDEB),
        incomeContainer: Color(0xFFE7F6EC),
        neutralContainer: Color(0xFFEFEFE4),
      );

  /// 支出还是收入对应的颜色。
  Color moneyColor(String type) =>
      type == 'income' ? appColors.income : appColors.expense;

  /// 支出还是收入对应的浅色底。
  Color moneyContainer(String type) =>
      type == 'income' ? appColors.incomeContainer : appColors.expenseContainer;
}

/// 统一的圆角。
///
/// 以前每个页面各写各的（12、14、16、20 都有），整个 App 看起来像几块拼起来的。
class AppRadius {
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 26;
}

/// 构建 App 主题。
ThemeData buildAppTheme({required Brightness brightness}) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF4CAF50),
    brightness: brightness,
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);

  final appColors = AppColors(
    brightness: brightness,
    expense: isDark ? const Color(0xFFFF8A80) : const Color(0xFFD64541),
    income: isDark ? const Color(0xFF7BD8A2) : const Color(0xFF1E8E4E),
    expenseContainer:
        isDark ? const Color(0xFF3B2220) : const Color(0xFFFFEDEA),
    incomeContainer: isDark ? const Color(0xFF17301F) : const Color(0xFFE6F5EB),
    neutralContainer: scheme.surfaceContainerHighest,
  );

  final textTheme = base.textTheme.apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  return base.copyWith(
    extensions: [appColors],
    textTheme: textTheme,
    // 水波纹比旧的墨水涟漪更顺滑，滑动时更跟手。
    splashFactory: InkSparkle.splashFactory,
    splashColor: scheme.primary.withOpacity(0.08),
    highlightColor: scheme.primary.withOpacity(0.04),

    // 统一圆角。
    cardTheme: CardTheme(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: scheme.outlineVariant.withOpacity(0.6)),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      showCheckmark: false,
      labelStyle: const TextStyle(fontSize: 13),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withOpacity(0.6),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    dialogTheme: DialogTheme(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: scheme.outlineVariant,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      insetPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      titleTextStyle: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 3,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      height: 68,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 3,
      highlightElevation: 6,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: scheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
    ),
    // 页面切换用淡入 + 轻微上移，比默认的横向滑动更轻。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );
}
