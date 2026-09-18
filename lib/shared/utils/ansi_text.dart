import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class AnsiTextTheme {
  final Color foreground;
  final Color background;

  const AnsiTextTheme({required this.foreground, required this.background});
}

/// 某一行开头时生效的 ANSI 样式（前景 / 背景 / 粗体）。
///
/// 日志改成按行懒渲染之后，每行是单独解析的；但颜色序列可以跨行生效
/// （`\x1B[31m` 开头、隔几行才 `\x1B[0m`）。整段解析时状态会自然往下传，
/// 拆成行以后就得把「上一行结束时的状态」记下来交给下一行，否则跨行的颜色会丢。
///
/// 这里只记「第几号色 / 哪个 RGB」，与配色无关：日志底色是异步加载的、
/// 明暗也可能切换，状态要能在配色变了之后原样复用，不必重扫整段日志。
class AnsiLineState {
  const AnsiLineState._(this._style);

  final _AnsiStyleState _style;

  static const AnsiLineState initial = AnsiLineState._(_AnsiStyleState.plain);

  /// 扫一遍 [line] 里的 SGR 序列，返回行尾时生效的状态。只推状态，不构建 span。
  AnsiLineState advance(String line) {
    // 绝大多数日志行不带转义序列，先用 contains 挡掉，省一次正则扫描。
    if (!line.contains('\x1B')) {
      return this;
    }
    var style = _style;
    for (final match in AnsiTextParser._ansiPattern.allMatches(line)) {
      style = style.applyCodes(AnsiTextParser._parseCodes(match.group(1)));
    }
    return AnsiLineState._(style);
  }
}

class AnsiTextParser {
  static final RegExp _ansiPattern = RegExp(r'\x1B\[([0-9;]*)m');

  /// [start] 是这段文本开头时已经生效的样式，按行渲染时传上一行结束时的状态；
  /// 整段解析保持默认值即可。
  static TextSpan buildTextSpan(
    String text, {
    required TextStyle baseStyle,
    required Brightness brightness,
    AnsiLineState start = AnsiLineState.initial,
  }) {
    final palette = _paletteForBrightness(
      brightness,
      defaultForeground: baseStyle.color,
    );
    final spans = <InlineSpan>[];
    var state = start._style;
    var cursor = 0;

    for (final match in _ansiPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: text.substring(cursor, match.start),
            style: state.toTextStyle(baseStyle, palette),
          ),
        );
      }

      final codes = _parseCodes(match.group(1));
      state = state.applyCodes(codes);
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(cursor),
          style: state.toTextStyle(baseStyle, palette),
        ),
      );
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text, style: baseStyle));
    }

    return TextSpan(children: spans, style: baseStyle);
  }

  static List<int> _parseCodes(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const [0];
    }
    return raw
        .split(';')
        .map((item) => int.tryParse(item) ?? 0)
        .toList(growable: false);
  }

  static _AnsiPalette _paletteForBrightness(
    Brightness brightness, {
    Color? defaultForeground,
  }) {
    if (brightness == Brightness.dark) {
      return _AnsiPalette(
        defaultForeground: defaultForeground ?? AppColors.slate50,
        defaultBackground: Colors.transparent,
        colors: const [
          AppColors.slate400,
          Color(0xFFF87171),
          AppColors.termGreen,
          Color(0xFFFBBF24),
          AppColors.termBlue,
          Color(0xFFC084FC),
          Color(0xFF22D3EE),
          Color(0xFFE5E7EB),
        ],
        brightColors: const [
          AppColors.slate200,
          Color(0xFFFCA5A5),
          Color(0xFF6EE7B7),
          Color(0xFFFCD34D),
          Color(0xFF93C5FD),
          Color(0xFFD8B4FE),
          Color(0xFF67E8F9),
          Color(0xFFFFFFFF),
        ],
      );
    }

    return _AnsiPalette(
      defaultForeground: defaultForeground ?? AppColors.slate700,
      defaultBackground: Colors.transparent,
      colors: const [
        Color(0xFF111827),
        Color(0xFFDC2626),
        Color(0xFF059669),
        Color(0xFFD97706),
        Color(0xFF2563EB),
        Color(0xFF7C3AED),
        Color(0xFF0F766E),
        Color(0xFFE5E7EB),
      ],
      brightColors: const [
        Color(0xFF6B7280),
        Color(0xFFEF4444),
        Color(0xFF10B981),
        Color(0xFFF59E0B),
        Color(0xFF3B82F6),
        Color(0xFF8B5CF6),
        Color(0xFF14B8A6),
        Color(0xFFF8FAFC),
      ],
    );
  }
}

class _AnsiPalette {
  final Color defaultForeground;
  final Color defaultBackground;
  final List<Color> colors;
  final List<Color> brightColors;

  const _AnsiPalette({
    required this.defaultForeground,
    required this.defaultBackground,
    required this.colors,
    required this.brightColors,
  });
}

/// 与配色无关的颜色引用，渲染时才按当前配色落成具体颜色。
///
/// 以前状态里直接存解析好的 Color，跨行携带时配色一变（日志底色异步加载完）
/// 就全错了。30–37 / 90–97 / 40–47 / 100–107 统一记成 0–15 号索引色，
/// 与 `38;5;n` 走同一条 [_indexedColor]，解析结果与改造前逐一对得上。
abstract class _AnsiColor {
  const _AnsiColor();

  Color resolve(_AnsiPalette palette);
}

class _AnsiIndexedColor extends _AnsiColor {
  final int index;

  const _AnsiIndexedColor(this.index);

  @override
  Color resolve(_AnsiPalette palette) => _indexedColor(index, palette);
}

class _AnsiRgbColor extends _AnsiColor {
  final int red;
  final int green;
  final int blue;

  const _AnsiRgbColor(this.red, this.green, this.blue);

  @override
  Color resolve(_AnsiPalette palette) =>
      Color.fromARGB(0xFF, red, green, blue);
}

class _AnsiStyleState {
  /// null 表示「默认色」，由配色决定。
  final _AnsiColor? foreground;
  final _AnsiColor? background;
  final bool bold;

  const _AnsiStyleState({
    required this.foreground,
    required this.background,
    required this.bold,
  });

  static const _AnsiStyleState plain = _AnsiStyleState(
    foreground: null,
    background: null,
    bold: false,
  );

  _AnsiStyleState applyCodes(List<int> codes) {
    var nextForeground = foreground;
    var nextBackground = background;
    var nextBold = bold;

    for (var i = 0; i < codes.length; i++) {
      final code = codes[i];
      switch (code) {
        case 0:
          nextForeground = null;
          nextBackground = null;
          nextBold = false;
          break;
        case 1:
          nextBold = true;
          break;
        case 22:
          nextBold = false;
          break;
        case 39:
          nextForeground = null;
          break;
        case 49:
          nextBackground = null;
          break;
        default:
          if (code >= 30 && code <= 37) {
            nextForeground = _AnsiIndexedColor(code - 30);
          } else if (code >= 90 && code <= 97) {
            nextForeground = _AnsiIndexedColor(code - 90 + 8);
          } else if (code >= 40 && code <= 47) {
            nextBackground = _AnsiIndexedColor(code - 40);
          } else if (code >= 100 && code <= 107) {
            nextBackground = _AnsiIndexedColor(code - 100 + 8);
          } else if (code == 38 || code == 48) {
            final isForeground = code == 38;
            final parsed = _parseExtendedColor(codes, i);
            if (parsed.color != null) {
              if (isForeground) {
                nextForeground = parsed.color;
              } else {
                nextBackground = parsed.color;
              }
            }
            i = parsed.nextIndex;
          }
      }
    }

    return _AnsiStyleState(
      foreground: nextForeground,
      background: nextBackground,
      bold: nextBold,
    );
  }

  TextStyle toTextStyle(TextStyle baseStyle, _AnsiPalette palette) {
    final resolvedForeground =
        foreground?.resolve(palette) ?? palette.defaultForeground;
    final resolvedBackground =
        background?.resolve(palette) ?? palette.defaultBackground;
    return baseStyle.copyWith(
      color: resolvedForeground,
      backgroundColor: resolvedBackground == Colors.transparent
          ? null
          : resolvedBackground,
      fontWeight: bold ? FontWeight.w700 : baseStyle.fontWeight,
    );
  }

  _ExtendedColorResult _parseExtendedColor(List<int> codes, int index) {
    if (index + 1 >= codes.length) {
      return _ExtendedColorResult(null, index);
    }

    final mode = codes[index + 1];
    if (mode == 5) {
      if (index + 2 >= codes.length) {
        return _ExtendedColorResult(null, index + 1);
      }
      return _ExtendedColorResult(
        _AnsiIndexedColor(codes[index + 2]),
        index + 2,
      );
    }

    if (mode == 2) {
      if (index + 4 >= codes.length) {
        return _ExtendedColorResult(null, codes.length - 1);
      }
      return _ExtendedColorResult(
        _AnsiRgbColor(
          codes[index + 2].clamp(0, 255),
          codes[index + 3].clamp(0, 255),
          codes[index + 4].clamp(0, 255),
        ),
        index + 4,
      );
    }

    return _ExtendedColorResult(null, index + 1);
  }
}

Color _indexedColor(int index, _AnsiPalette palette) {
  if (index < 0) {
    return palette.defaultForeground;
  }
  if (index < 8) {
    return palette.colors[index];
  }
  if (index < 16) {
    return palette.brightColors[index - 8];
  }
  if (index >= 232 && index <= 255) {
    final level = ((index - 232) * 10) + 8;
    return Color.fromARGB(0xFF, level, level, level);
  }
  if (index >= 16 && index <= 231) {
    final normalized = index - 16;
    final red = normalized ~/ 36;
    final green = (normalized % 36) ~/ 6;
    final blue = normalized % 6;
    int component(int value) => value == 0 ? 0 : 55 + value * 40;
    return Color.fromARGB(
      0xFF,
      component(red),
      component(green),
      component(blue),
    );
  }
  return palette.defaultForeground;
}

class _ExtendedColorResult {
  final _AnsiColor? color;
  final int nextIndex;

  const _ExtendedColorResult(this.color, this.nextIndex);
}
