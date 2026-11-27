import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// 全局色值与终端语义色 —— 对齐 v3.0 Nordic Calm 设计系统。
///
/// 这些是不分明暗的常量，钴蓝 / 红 / 绿 / 紫都是按浅色底调的：放到深色
/// 卡片上当文字只有 3.1~3.5:1，[slate800] 还与深色卡片同值。界面颜色一律走
/// `context.palette`，这里只留给终端、编辑器这类自带底色的固定配色。
class AppColors {
  // Primary（Nordic Cobalt 钴蓝体系）
  static const primary = Color(0xFF2B5BEE);
  static const primaryLight = Color(0xFFEEF3FE);
  static const primaryDark = Color(0xFF224BC9);

  // 中性石色与灰阶（兼容次级组件）
  static const slate50 = Color(0xFFFAF9F6);
  static const slate100 = Color(0xFFF3F1EC);
  static const slate200 = Color(0xFFE5E2DC);
  static const slate300 = Color(0xFFD6D3CD);
  static const slate400 = Color(0xFFA8A29E);
  static const slate500 = Color(0xFF78716C);
  static const slate600 = Color(0xFF57534E);
  static const slate700 = Color(0xFF32363F);
  static const slate800 = Color(0xFF1B1D21);
  static const slate900 = Color(0xFF14161A);
  static const slate950 = Color(0xFF0C0D10);

  // 功能色
  static const blue500 = Color(0xFF2B5BEE);
  static const blue600 = Color(0xFF224BC9);
  static const blue100 = Color(0xFFDCE6FD);
  static const purple500 = Color(0xFF6D5BD0);
  static const purple600 = Color(0xFF5845BC);
  static const purple100 = Color(0xFFEDE9FE);
  static const red500 = Color(0xFFDC2626);
  static const red600 = Color(0xFFC81E1E);
  static const red100 = Color(0xFFFEE2E2);
  static const red50 = Color(0xFFFEF2F2);
  static const amber500 = Color(0xFFD97706);

  // ── 语义状态色 ────────────────────────────────────────
  static const success = Color(0xFF15803D);
  static const successDark = Color(0xFF147538);
  static const successLight = Color(0xFFECFDF3);

  static const info = primary;
  static const infoDark = primaryDark;
  static const infoLight = primaryLight;

  static const danger = red500;
  static const dangerDark = red600;
  static const dangerLight = red100;

  static const warning = amber500;
  static const neutral = slate500;

  // ── 代码编辑器与日志页内搜索高亮 ──────────────────────
  static const searchMatch = Color(0x4DEAB308);
  static const searchMatchCurrent = Color(0x99EAB308);

  static const editorGutterOnDark = Color(0xFF6B7280);
  static const editorGutterOnLight = slate400;

  // ── 全屏沉浸式实时日志终端配色（方案 1 Nordic Calm） ────
  /// 默认暖纸护眼浅底（`#FAF9F6`）。
  static const termBgLight = Color(0xFFFAF9F6);

  /// 独立护眼深邃暗底终端（`#14161A`）。
  static const termBgDark = Color(0xFF14161A);

  static const termText = Color(0xFF1C1917);
  static const termBlue = Color(0xFF6C93FF);
  static const termGreen = Color(0xFF22C55E);
  static const termRed = Color(0xFFF87171);
}

/// v3.0 主题：将全部 Material 3 组件统一映射到 [AppPalette]（Nordic Calm）。
class AppTheme {
  static ThemeData light() => _buildTheme(AppPalette.light, Brightness.light);

  static ThemeData dark() => _buildTheme(AppPalette.dark, Brightness.dark);

  static ThemeData _buildTheme(AppPalette p, Brightness brightness) {
    // primary / error 就是状态实色 accent / err，压在上面的前景跟 onStatus 走：
    // 深色下它们提亮了，写死白色时 Checkbox 的勾只有 2.89:1。
    final cs = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      primary: p.accent,
      onPrimary: p.onStatus,
      secondary: p.accent,
      onSecondary: p.onStatus,
      surface: p.bg,
      onSurface: p.text,
      onSurfaceVariant: p.text2,
      outline: p.separator,
      outlineVariant: p.separator,
      error: p.err,
      onError: p.onStatus,
      surfaceContainerLowest: p.card,
      surfaceContainerLow: p.card,
      surfaceContainer: p.card,
      surfaceContainerHigh: p.card,
      surfaceContainerHighest: p.card2,
      inverseSurface: p.text,
      onInverseSurface: p.card,
    );

    const inputRadius = BorderRadius.all(Radius.circular(AppRadius.md));
    const noBorder = OutlineInputBorder(
      borderRadius: inputRadius,
      borderSide: BorderSide.none,
    );

    final base = ThemeData(useMaterial3: true, colorScheme: cs);

    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      dividerColor: p.separator,
      extensions: <ThemeExtension<dynamic>>[p],
      textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
      iconTheme: IconThemeData(color: p.text, size: 20),
      splashFactory: NoSplash.splashFactory,
      highlightColor: p.fill,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.text,
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: p.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
        ),
        margin: const EdgeInsets.only(bottom: 12),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: noBorder,
        enabledBorder: noBorder,
        disabledBorder: noBorder,
        focusedBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: p.accent, width: AppBorderWidth.focus),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: p.err),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: inputRadius,
          borderSide: BorderSide(color: p.err, width: AppBorderWidth.focus),
        ),
        filled: true,
        fillColor: p.card2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        hintStyle: TextStyle(color: p.text3, fontSize: 14),
        labelStyle: TextStyle(
          color: p.text2,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        prefixIconColor: p.text2,
        suffixIconColor: p.text2,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.primaryBtnBg,
          foregroundColor: p.primaryBtnFg,
          disabledBackgroundColor: p.fill,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 44),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
          elevation: 0,
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primaryBtnBg,
          foregroundColor: p.primaryBtnFg,
          disabledBackgroundColor: p.fill,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 44),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
          elevation: 0,
          shadowColor: Colors.transparent,
          textStyle: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.card2,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 42),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
          side: BorderSide.none,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accentInk,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.text),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.primaryBtnBg,
        foregroundColor: p.primaryBtnFg,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: const StadiumBorder(),
      ),
      switchTheme: SwitchThemeData(
        // 打开时滑块压在 accent 轨道上，和 Checkbox 的勾一样跟 onStatus 走：
        // 深色 accent 提亮后，白滑块只剩 2.89:1，不到非文字的 3:1。
        // 关闭时轨道是半透明 fill，白滑块照旧。
        thumbColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? p.onStatus
              : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.accent : p.fill;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
        ),
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.accent : null;
        }),
        // 勾压在 accent 实底上，与 fillColor 成对写明，不靠 onPrimary 间接推。
        checkColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.onStatus : null;
        }),
        side: BorderSide(color: p.text3, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.accent : p.text3;
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.fill,
        circularTrackColor: Colors.transparent,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.accent,
        inactiveTrackColor: p.fill,
        thumbColor: Colors.white,
      ),
      dividerTheme: DividerThemeData(
        color: p.separator,
        thickness: 0.5,
        space: 0,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.text2,
        textColor: p.text,
        subtitleTextStyle: TextStyle(color: p.text2, fontSize: 12.5),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.card2,
        selectedColor: p.primaryBtnBg,
        secondarySelectedColor: p.primaryBtnBg,
        checkmarkColor: p.primaryBtnFg,
        labelStyle: TextStyle(
          color: p.text,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          color: p.primaryBtnFg,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.accentInk,
        unselectedLabelColor: p.text2,
        indicatorColor: p.accent,
        dividerColor: Colors.transparent,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.card,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.card,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.card),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.card,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: const Color(0x140F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: p.separator),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
        ),
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(color: p.text, fontSize: 14, height: 1.5),
        actionsPadding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: 0.22),
        selectionHandleColor: p.accent,
      ),
    );
  }
}
