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

  // 日志终端
  static const termBg = Colors.white;
  static const termBgDark = Color(0xFF000000);
  static const termText = Color(0xFF0F172A); // slate-900
  static const termBlue = Color(0xFF60A5FA); // blue-400
  static const termGreen = Color(0xFF34D399); // emerald-400
  static const termRed = Color(0xFFF87171); // red-400
}

class AppTheme {
  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.blue500,
      surface: AppColors.slate50,
      onSurface: AppColors.slate900,
      onSurfaceVariant: AppColors.slate500,
      outline: AppColors.slate200,
      outlineVariant: AppColors.slate100,
      error: AppColors.red500,
      surfaceContainerHighest: AppColors.slate100,
    );
    return _buildTheme(colorScheme);
  }

  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      primary: AppColors.primary,
      onPrimary: Colors.white,
      secondary: AppColors.blue500,
      surface: AppColors.slate950,
      onSurface: AppColors.slate50,
      onSurfaceVariant: AppColors.slate400,
      outline: AppColors.slate800,
      outlineVariant: AppColors.slate800,
      error: AppColors.red500,
      surfaceContainerHighest: AppColors.slate900,
    );
    return _buildTheme(colorScheme);
  }

  static ThemeData _buildTheme(ColorScheme cs) {
    final isLight = cs.brightness == Brightness.light;
    final cardColor = isLight ? Colors.white : AppColors.slate900;
    final borderColor = isLight ? AppColors.slate200 : AppColors.slate800;

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        titleTextStyle: TextStyle(
          color: cs.onSurface,
          fontSize: 24,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cardColor,
        shape: RoundedRectangleBorder(
          // 区块级大卡片，与 AppCard 同档 —— 全库只有 6 处走 Flutter Card，
          // 其中 3 处是 backup_page 的整页结构面板，这一档在那一页上是看得见的。
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: borderColor, width: 1),
        ),
        margin: const EdgeInsets.only(bottom: 12),
      ),
      // ⚠️ 下面 border / enabledBorder / focusedBorder 三处圆角**必须同值**。
      // 聚焦是三个 border 之间的插值动画，任何一处不一致都会让动画中途出现
      // 角忽大忽小的抖动 —— 静态截图看不出来，只有点进输入框的那一瞬间才有。
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: isLight ? AppColors.slate300 : AppColors.slate600,
          fontSize: 14,
        ),
        labelStyle: TextStyle(
          color: cs.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          elevation: 0,
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          side: BorderSide(color: borderColor),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? AppColors.primary
              : isLight
              ? AppColors.slate300
              : AppColors.slate700;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          return states.contains(WidgetState.selected)
              ? Colors.transparent
              : isLight
              ? AppColors.slate400
              : AppColors.slate600;
        }),
      ),
      dividerTheme: DividerThemeData(
        color: borderColor,
        thickness: 1,
        space: 0,
      ),
      // 零像素变化：Chip 默认高 32，圆角在绘制时会被 clamp 到高的一半（16），
      // 原先写的 20 从来没有生效过 —— 它渲染出来本来就是胶囊，这里只是把
      // 「实际是什么」写成「代码里说的是什么」。
      chipTheme: const ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        ),
      ),
      // Checkbox 走**控件**档，不跟表面档一起收缩，理由见 AppRadius.control。
      // 这一处同时收编两类站点：2 处本地写死 4 的（login / log_list）与
      // 7 处走 Material 默认约 2dp 的，改完 9 个勾选框第一次是同一个圆角。
      checkboxTheme: const CheckboxThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        // 扁平化：去掉 M3 给弹出菜单的默认投影，改由 1px 边框做唯一分隔物。
        // 菜单浮在页面之上、没有遮罩，去掉投影后必须补边框，否则与下方内容糊在一起。
        // 这一处一次覆盖全库 7 个 PopupMenuButton。
        elevation: 0,
        shadowColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: borderColor),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        // 弹窗与底部面板同为「浮在页面上的容器」，统一走 lg，不再一个 20 一个 20
        // 却各写各的。
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      ),
    );
  }

  // 原先这里有一组 successColor / errorColor / warningColor / runningColor /
  // disabledColor 常量，全库零引用，且主色换蓝之后 successColor 与 runningColor
  // 双双等于 AppColors.primary —— 一组既没人用、语义又是错的假常量。
  // 已删除，状态色统一由 AppColors.success / info / danger / warning / neutral 提供，
  // 并在各状态判断处真正使用。
}
