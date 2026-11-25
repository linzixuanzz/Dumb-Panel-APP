import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// 设计系统色板 — 基于面板主色（Element Plus 蓝）+ Slate
class AppColors {
  // Primary
  // 与呆呆面板 v3.0.0 的 --el-color-primary 对齐，APP 不再自成一套 Emerald 绿。
  // 浅/深变体取 Element Plus 的 primary-light-9 / primary-dark-2。
  static const primary = Color(0xFF409EFF); // Element Plus primary
  static const primaryLight = Color(0xFFECF5FF); // primary-light-9
  static const primaryDark = Color(0xFF337ECC); // primary-dark-2

  // Slate 体系
  static const slate50 = Color(0xFFF8FAFC);
  static const slate100 = Color(0xFFF1F5F9);
  static const slate200 = Color(0xFFE2E8F0);
  static const slate300 = Color(0xFFCBD5E1);
  static const slate400 = Color(0xFF94A3B8);
  static const slate500 = Color(0xFF64748B);
  static const slate600 = Color(0xFF475569);
  static const slate700 = Color(0xFF334155);
  static const slate800 = Color(0xFF1E293B);
  static const slate900 = Color(0xFF0F172A);
  static const slate950 = Color(0xFF020617);

  // 功能色
  static const blue500 = Color(0xFF3B82F6);
  static const blue600 = Color(0xFF2563EB);
  static const blue100 = Color(0xFFDBEAFE);
  static const purple500 = Color(0xFF8B5CF6);
  static const purple600 = Color(0xFF7C3AED);
  static const purple100 = Color(0xFFEDE9FE);
  static const red500 = Color(0xFFEF4444);
  static const red600 = Color(0xFFDC2626);
  static const red100 = Color(0xFFFEE2E2);
  static const red50 = Color(0xFFFEF2F2);
  static const amber500 = Color(0xFFF59E0B);

  // ── 语义状态色 ────────────────────────────────────────
  // 主色从 Emerald 绿换成 Element Plus 蓝之后，「成功 / 已启用」不能再借用 primary
  // 表达，否则与「运行中 / 进行中」的蓝完全同色。这里给四态各自的专属色，
  // 页面只引用这些语义名，不再直接挑 primary / blue500 当状态色。
  //
  // 绿色取面板 Element Plus 的 --el-color-success 全家桶，与主色同源；
  // warning / danger 复用已有的 amber / red，只建立语义别名，避免无谓的视觉变动。

  /// 成功 / 已启用 / 已安装。用作状态圆点与深色模式前景。
  static const success = Color(0xFF67C23A); // el-color-success

  /// 浅色模式下的成功前景（徽章文字）。
  static const successDark = Color(0xFF529B2E); // el success-dark-2

  /// 浅色模式下的成功淡底（徽章背景）。
  static const successLight = Color(0xFFF0F9EB); // el success-light-9

  /// 运行中 / 进行中 / 信息。蓝色语义就是主色语义，直接等同 primary。
  static const info = primary;
  static const infoDark = primaryDark;
  static const infoLight = primaryLight;

  /// 失败 / 危险。沿用既有 red，只给语义名。
  static const danger = red500;
  static const dangerDark = red600;
  static const dangerLight = red100;

  /// 排队中 / 警告。沿用既有 amber，只给语义名。
  static const warning = amber500;

  /// 已禁用 / 已取消等中性态前景。
  static const neutral = slate500;

  // ── 代码编辑器 ────────────────────────────────────────
  //
  // 取值全部对齐面板 Web 的 CodeMirror 主题（web/src/utils/codeEditor.ts），
  // 两端观感才是同一个产品。
  //
  // ⚠️ 这里的黄是 `#EAB308`（Tailwind yellow-500），**不是** [amber500] 的
  // `#F59E0B`（Tailwind amber-500）。它们不是同一个黄，别顺手复用 amber500。

  /// 搜索命中：全部命中的弱高亮底色（= `rgba(234,179,8,0.35)`）。
  static const searchMatch = Color(0x59EAB308);

  /// 搜索命中：当前那一个的强高亮底色（= `rgba(234,179,8,0.6)`）。
  static const searchMatchCurrent = Color(0x99EAB308);

  /// 行号栏文字，**深底**时用（面板 Web gutter 深色 `#6b7280`）。
  ///
  /// 选深色还是浅色看的是**编辑器底色**而不是 App 主题：editor_background_color
  /// 是用户在面板里自定义的，深色模式配浅底、浅色模式配深底都合法。
  static const editorGutterOnDark = Color(0xFF6B7280);

  /// 行号栏文字，**浅底**时用。取值与面板 Web gutter 浅色 `#94a3b8` 完全一致。
  static const editorGutterOnLight = slate400;

  // 日志终端
  //
  // 面板的 log_background_color 出厂默认是空串，注册说明写的是「留空跟随当前主题」
  // （server/model/system_config_registry.go）。所以这两个值是「面板没配色时」的兜底，
  // 取值直接对齐面板 Web 的 DEFAULT_LOG_BACKGROUND_COLOR_LIGHT/DARK
  // （web/src/utils/panelAppearance.ts），两端观感才是同一个产品。
  //
  // 别再写回 Colors.white / 纯黑：旧版只有一个恒定白底的 termBg，深色模式下日志就是刺眼的白，
  // 这正是 issue #2 的根因。
  static const termBgLight = Color(0xFFF8FAFC); // = slate50
  static const termBgDark = Color(0xFF0F172A); // = slate900
  static const termText = Color(0xFF0F172A); // slate-900
  static const termBlue = Color(0xFF60A5FA); // blue-400
  static const termGreen = Color(0xFF34D399); // emerald-400
  static const termRed = Color(0xFFF87171); // red-400
}

/// v2.0 主题：全部 Material 组件映射到 [AppPalette]。
///
/// 目的是「次级页面不改代码也能换装」：脚本、订阅、依赖这些页面大量直接用
/// `TextField` / `FilledButton` / `Switch` / `AlertDialog`，它们的外观都从这里来。
/// 新组件（分组列表、胶囊按钮、底栏）是自绘的，不靠这里。
class AppTheme {
  static ThemeData light() => _buildTheme(AppPalette.light, Brightness.light);

  static ThemeData dark() => _buildTheme(AppPalette.dark, Brightness.dark);

  static ThemeData _buildTheme(AppPalette p, Brightness brightness) {
    final cs = ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      primary: p.accent,
      onPrimary: Colors.white,
      secondary: p.accent,
      onSecondary: Colors.white,
      // surface 是页面底色：v1.x 的页面大多直接用 colorScheme.surface 当背景。
      surface: p.bg,
      onSurface: p.text,
      onSurfaceVariant: p.text2,
      outline: p.separator,
      outlineVariant: p.separator,
      error: p.err,
      onError: Colors.white,
      surfaceContainerLowest: p.card,
      surfaceContainerLow: p.card,
      surfaceContainer: p.card,
      surfaceContainerHigh: p.card,
      surfaceContainerHighest: p.card2,
      // SnackBar 的中性色调走 inverseSurface（见 AppSnack），与主按钮同一对黑白。
      inverseSurface: p.primaryBtnBg,
      onInverseSurface: p.primaryBtnFg,
    );

    // ⚠️ 下面 border / enabledBorder / focusedBorder 三处圆角**必须同值**。
    // 聚焦是三个 border 之间的插值动画，任何一处不一致都会让动画中途出现
    // 角忽大忽小的抖动 —— 静态截图看不出来，只有点进输入框的那一瞬间才有。
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
      iconTheme: IconThemeData(color: p.text),
      // 点按反馈：iOS 风格是整行变灰，不要 Material 的水波纹扩散。
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
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: p.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.cardSm)),
        ),
        margin: const EdgeInsets.only(bottom: 12),
      ),
      // 输入框：iOS 搜索框式的灰色填充、无描边，聚焦时才出一圈强调色。
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
        fillColor: p.fill,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(color: p.text3, fontSize: 15),
        labelStyle: TextStyle(
          color: p.text2,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
        prefixIconColor: p.text2,
        suffixIconColor: p.text2,
      ),
      // 主按钮：黑色胶囊（深色白色胶囊）。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.primaryBtnBg,
          foregroundColor: p.primaryBtnFg,
          disabledBackgroundColor: p.fill,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 48),
          shape: const StadiumBorder(),
          elevation: 0,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primaryBtnBg,
          foregroundColor: p.primaryBtnFg,
          disabledBackgroundColor: p.fill,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 48),
          shape: const StadiumBorder(),
          elevation: 0,
          shadowColor: Colors.transparent,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      // 次要按钮：灰色填充胶囊，没有描边。
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.text,
          backgroundColor: p.fill,
          disabledForegroundColor: p.text3,
          minimumSize: const Size(0, 44),
          shape: const StadiumBorder(),
          side: BorderSide.none,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
      // 开关：iOS 绿，白色圆钮，关着时是灰色填充、不画描边。
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.ok : p.fill;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      checkboxTheme: CheckboxThemeData(
        // Checkbox 走**控件**档，不跟表面档一起收缩，理由见 AppRadius.control。
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
        ),
        fillColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected) ? p.accent : null;
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
        subtitleTextStyle: TextStyle(color: p.text2, fontSize: 13.5),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.fill,
        selectedColor: p.primaryBtnBg,
        secondarySelectedColor: p.primaryBtnBg,
        checkmarkColor: p.primaryBtnFg,
        labelStyle: TextStyle(color: p.text, fontSize: 13),
        secondaryLabelStyle: TextStyle(color: p.primaryBtnFg, fontSize: 13),
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.text,
        unselectedLabelColor: p.text2,
        indicatorColor: p.text,
        dividerColor: Colors.transparent,
      ),
      // 底部面板：顶部大圆角。拖拽把手不在主题里统一开（会给全部旧面板顶部
      // 多塞 48dp，旧面板的高度都是按没有把手算的），新弹层走 showAppSheet 自带把手。
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
        // 浮层不靠投影分层：用一圈分隔线色的细边。
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: p.separator),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.cardSm)),
        ),
        titleTextStyle: TextStyle(
          color: p.text,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: TextStyle(color: p.text, fontSize: 15, height: 1.45),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.accent,
        selectionColor: p.accent.withValues(alpha: 0.25),
        selectionHandleColor: p.accent,
      ),
    );
  }
}
