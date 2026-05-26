// デザイントークンの最小セット (Sprint 6 Feature 6.4 で本実装化)。
//
// 第二段階 (Figma / Claude Design) の受け皿として、色・spacing・typography・radius の
// 基礎トークンと Material ThemeExtension を定義する。新規コードではハードコードではなく
// ここを経由すること。第二段階でトークン値だけを差し替えれば UI 全体が追従する。
//
// 本ファイルは Dart のみの依存に留める (Figma plugin / Design Tokens Community Group の
// JSON からの自動生成は将来の課題)。値は SwiftUI 版の挙動と Sprint 4 の Feature 4.2 の
// WCAG AA 要件を踏襲する。

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// ColorTokens
// ---------------------------------------------------------------------------

/// 基調色と 11 ノートカラーの定義 (Phase 2 視覚移植)。
///
/// ノートカラーテーマは SwiftUI `StickyNote.swift` の NoteColorTheme enum 定義を
/// そのまま踏襲する。SwiftUI の `Color(red: _, green: _, blue: _)` は sRGB float 値なので、
/// Dart の `Color.fromRGBO(r*255, g*255, b*255)` に変換する。
///
/// 第二段階で Figma トークンの受け皿にする際は、ここの値だけ差し替えれば
/// 呼び出し側のコードは一切変更不要 (Material ThemeExtension 経由のため)。
class ColorTokens {
  ColorTokens._();

  // 基調色
  static const Color surface = Color(0xFFFAFAFA);
  static const Color surfaceMuted = Color(0xFFF2F2F5);
  static const Color onSurface = Color(0xFF1C1C1E);
  static const Color onSurfaceMuted = Color(0xFF6E6E73);
  static const Color accent = Color(0xFFFFB300);
  static const Color error = Color(0xFFD32F2F);
  static const Color outline = Color(0xFFD9D9DE);
  static const Color shadow = Color(0x1A000000);

  // ノートカラー 背景 (SwiftUI NoteColorTheme.backgroundColor と exact 一致)。
  // SwiftUI 値 -> 8bit RGB: floor(value * 255 + 0.5)
  static const Color noteYellow = Color.fromARGB(255, 255, 249, 196);
  static const Color notePink = Color.fromARGB(255, 255, 224, 230);
  static const Color noteBlue = Color.fromARGB(255, 212, 234, 255);
  static const Color noteGreen = Color.fromARGB(255, 220, 249, 220);
  static const Color notePurple = Color.fromARGB(255, 234, 212, 249);
  static const Color noteOrange = Color.fromARGB(255, 255, 235, 199);
  static const Color noteCoral = Color.fromARGB(255, 255, 221, 213);
  static const Color noteMint = Color.fromARGB(255, 212, 249, 241);
  static const Color noteLavender = Color.fromARGB(255, 228, 221, 255);
  static const Color notePeach = Color.fromARGB(255, 255, 231, 221);
  static const Color noteSky = Color.fromARGB(255, 220, 241, 255);

  // ノートカラー toolbar (SwiftUI NoteColorTheme.toolbarColor と exact 一致)。
  static const Color toolbarYellow = Color.fromARGB(255, 243, 236, 178);
  static const Color toolbarPink = Color.fromARGB(255, 243, 209, 216);
  static const Color toolbarBlue = Color.fromARGB(255, 196, 221, 243);
  static const Color toolbarGreen = Color.fromARGB(255, 204, 238, 204);
  static const Color toolbarPurple = Color.fromARGB(255, 221, 200, 238);
  static const Color toolbarOrange = Color.fromARGB(255, 243, 222, 181);
  static const Color toolbarCoral = Color.fromARGB(255, 243, 207, 197);
  static const Color toolbarMint = Color.fromARGB(255, 197, 238, 229);
  static const Color toolbarLavender = Color.fromARGB(255, 215, 207, 243);
  static const Color toolbarPeach = Color.fromARGB(255, 243, 218, 207);
  static const Color toolbarSky = Color.fromARGB(255, 206, 229, 243);

  // ノートカラー テキスト色 (SwiftUI NoteColorTheme.textColor と exact 一致)。
  // 各背景で WCAG AA 4.5:1 以上を満たすよう SwiftUI 側で事前計算済みの値。
  static const Color textYellow = Color.fromARGB(255, 56, 48, 10);
  static const Color textPink = Color.fromARGB(255, 61, 24, 32);
  static const Color textBlue = Color.fromARGB(255, 16, 32, 56);
  static const Color textGreen = Color.fromARGB(255, 16, 40, 16);
  static const Color textPurple = Color.fromARGB(255, 32, 10, 56);
  static const Color textOrange = Color.fromARGB(255, 60, 40, 0);
  static const Color textCoral = Color.fromARGB(255, 61, 16, 8);
  static const Color textMint = Color.fromARGB(255, 8, 49, 44);
  static const Color textLavender = Color.fromARGB(255, 28, 8, 56);
  static const Color textPeach = Color.fromARGB(255, 61, 32, 10);
  static const Color textSky = Color.fromARGB(255, 6, 32, 48);

  /// ノート 11 色をまとめて順序固定で返すユーティリティ。
  ///
  /// NoteColorTheme.values と同じ並び:
  /// yellow/pink/blue/green/purple/orange/coral/mint/lavender/peach/sky。
  static const List<Color> noteColors = <Color>[
    noteYellow,
    notePink,
    noteBlue,
    noteGreen,
    notePurple,
    noteOrange,
    noteCoral,
    noteMint,
    noteLavender,
    notePeach,
    noteSky,
  ];
}

// ---------------------------------------------------------------------------
// SpacingTokens
// ---------------------------------------------------------------------------

/// 8 の倍数を基準とした spacing スケール (xs のみ 4)。
///
/// 基本は 4→8→16→24→32→48 の 6 段階。UI パーツの余白は必ずこれを参照する。
class SpacingTokens {
  SpacingTokens._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

// ---------------------------------------------------------------------------
// RadiusTokens
// ---------------------------------------------------------------------------

/// 角丸スケール。
///
/// Phase 2: SwiftUI `NoteView` は `cornerRadius 12 style: .continuous` を採用している
/// ため、ノートカード共通の角丸は `large(12)` を使う。
/// ボタン = small(4)、FAB / Chip = pill(9999)、中程度のカード = medium(8)。
class RadiusTokens {
  RadiusTokens._();

  static const double small = 4;
  static const double medium = 8;
  static const double large = 12;
  static const double pill = 9999;
}

// ---------------------------------------------------------------------------
// DimensionTokens
// ---------------------------------------------------------------------------

/// 固定サイズのスケール (Phase 2 視覚移植)。
///
/// SwiftUI 版 `GoldenRatio.swift` / `FloatingPanel.fixedContentWidth` に合わせる。
/// - noteFixedWidth: expanded / rolledUp ノート窓の固定幅 160px
/// - noteExpandedHeight: 新規作成時のデフォルト高さ 120px (golden medium)
/// - noteRolledUpHeight: 巻物バーの高さ 26px (SwiftUI 踏襲)
/// - noteMiniSize: mini ノート直径 36px (SwiftUI MiniNoteView 踏襲。従来 48 から縮小)
class DimensionTokens {
  DimensionTokens._();

  /// golden ratio φ。
  static const double phi = 1.6180339887;

  /// ノート窓の固定幅。
  static const double noteFixedWidth = 160;

  /// ノート窓 expanded デフォルト高さ (160 / φ ≒ 99 ではなく SwiftUI の medium=120 を採用)。
  static const double noteExpandedHeight = 120;

  /// 巻物バーの高さ。
  static const double noteRolledUpHeight = 26;

  /// mini ノートの直径 (SwiftUI MiniNoteView: 36x36)。
  static const double noteMiniSize = 36;
}

// ---------------------------------------------------------------------------
// TypographyTokens
// ---------------------------------------------------------------------------

/// タイポグラフィ 5 段階。
///
/// macOS 版 SwiftUI のフォント (San Francisco) と Windows の Segoe UI / Yu Gothic UI
/// を想定し、サイズは 11/13/17/28 の 4 段階 + bodyBold で計 5 段階。色は呼び出し側で
/// copyWith(color:) する前提 (トークン側では色を持たない、単一責任のため)。
class TypographyTokens {
  TypographyTokens._();

  static const TextStyle caption = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const TextStyle body = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.5,
  );

  static const TextStyle bodyBold = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.5,
  );

  static const TextStyle heading = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static const TextStyle display = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.15,
  );
}

// ---------------------------------------------------------------------------
// AppFontFamily (Phase 2: SwiftUI AppFont 対応)
// ---------------------------------------------------------------------------

/// Settings 画面で選択できるフォントファミリ。
///
/// SwiftUI `AppFont.swift` に 1:1 対応。macOS 上では SwiftUI 側と同じフォント名、
/// Windows 上では近い見た目のフォールバックフォントを当てる。
enum AppFontFamily {
  hiraginoSans, // 既定: 日本語クリーンサンセリフ
  hiraginoMincho, // 明朝
  sfPro, // システムサンセリフ
  newYork, // Apple セリフ
  monaco, // 等幅 (クラシック)
  menlo; // 等幅 (やや暖かい)

  /// Settings 画面のラベル。
  String get displayName {
    switch (this) {
      case AppFontFamily.hiraginoSans:
        return 'ヒラギノ角ゴ (Sans)';
      case AppFontFamily.hiraginoMincho:
        return 'ヒラギノ明朝 (Serif)';
      case AppFontFamily.sfPro:
        return 'SF Pro (System)';
      case AppFontFamily.newYork:
        return 'New York (Serif)';
      case AppFontFamily.monaco:
        return 'Monaco (Mono)';
      case AppFontFamily.menlo:
        return 'Menlo (Mono)';
    }
  }

  /// macOS 用の NSFont 名 (SwiftUI AppFont.fontName と 1:1)。
  ///
  /// Flutter TextStyle.fontFamily に直接渡して利用する。pubspec に asset 登録は
  /// しない (システムフォント参照のみ)。
  String get macosFontName {
    switch (this) {
      case AppFontFamily.hiraginoSans:
        return 'HiraginoSans-W3';
      case AppFontFamily.hiraginoMincho:
        return 'HiraMinProN-W3';
      case AppFontFamily.sfPro:
        return '.AppleSystemUIFont';
      case AppFontFamily.newYork:
        return 'NewYork';
      case AppFontFamily.monaco:
        return 'Monaco';
      case AppFontFamily.menlo:
        return 'Menlo';
    }
  }

  /// Windows / Linux 用フォールバック名。
  /// 等幅は Consolas、明朝は Yu Mincho、サンセリフは Yu Gothic UI を基本に。
  String get fallbackFontName {
    switch (this) {
      case AppFontFamily.hiraginoSans:
        return 'Yu Gothic UI';
      case AppFontFamily.hiraginoMincho:
        return 'Yu Mincho';
      case AppFontFamily.sfPro:
        return 'Segoe UI';
      case AppFontFamily.newYork:
        return 'Cambria';
      case AppFontFamily.monaco:
        return 'Consolas';
      case AppFontFamily.menlo:
        return 'Consolas';
    }
  }

  /// rawValue 相当の文字列 (SwiftUI AppFont.rawValue と一致)。
  String get persistenceKey => name;

  /// SharedPreferences / settings.json からパースする (不明値は hiraginoSans)。
  static AppFontFamily fromName(String? name) {
    if (name == null) return AppFontFamily.hiraginoSans;
    for (final family in AppFontFamily.values) {
      if (family.name == name) return family;
    }
    return AppFontFamily.hiraginoSans;
  }
}

// ---------------------------------------------------------------------------
// FloteThemeExtension: Material Theme への橋渡し
// ---------------------------------------------------------------------------

/// Material の `Theme.of(context).extension<FloteTheme>()` で参照できる
/// アプリ固有トークン集。
///
/// 使い方:
/// ```dart
/// final tokens = Theme.of(context).floteTheme;
/// Container(color: tokens.colors.surface, ...)
/// ```
///
/// 互換性: 呼び出し側は Theme 経由で参照するため、第二段階で値を差し替える際も
/// ThemeExtension 宣言を書き換えるだけで済み、Widget 側の修正は不要。
@immutable
class FloteTheme extends ThemeExtension<FloteTheme> {
  const FloteTheme({
    required this.colors,
    required this.spacing,
    required this.radius,
    required this.typography,
  });

  final FloteColorScheme colors;
  final FloteSpacing spacing;
  final FloteRadius radius;
  final FloteTypography typography;

  /// 現行 MVP の標準セット (tokens.dart の定数そのまま)。
  static const FloteTheme standard = FloteTheme(
    colors: FloteColorScheme.standard,
    spacing: FloteSpacing.standard,
    radius: FloteRadius.standard,
    typography: FloteTypography.standard,
  );

  @override
  FloteTheme copyWith({
    FloteColorScheme? colors,
    FloteSpacing? spacing,
    FloteRadius? radius,
    FloteTypography? typography,
  }) {
    return FloteTheme(
      colors: colors ?? this.colors,
      spacing: spacing ?? this.spacing,
      radius: radius ?? this.radius,
      typography: typography ?? this.typography,
    );
  }

  @override
  FloteTheme lerp(ThemeExtension<FloteTheme>? other, double t) {
    // トークン値は離散的なため、lerp はしきい値 0.5 で切り替える単純実装。
    // 第二段階でアニメーション遷移が必要になれば色だけ Color.lerp に差し替える。
    if (other is! FloteTheme) return this;
    return t < 0.5 ? this : other;
  }
}

@immutable
class FloteColorScheme {
  const FloteColorScheme({
    required this.surface,
    required this.surfaceMuted,
    required this.onSurface,
    required this.onSurfaceMuted,
    required this.accent,
    required this.error,
    required this.outline,
    required this.shadow,
    required this.noteColors,
  });

  final Color surface;
  final Color surfaceMuted;
  final Color onSurface;
  final Color onSurfaceMuted;
  final Color accent;
  final Color error;
  final Color outline;
  final Color shadow;
  final List<Color> noteColors;

  static const FloteColorScheme standard = FloteColorScheme(
    surface: ColorTokens.surface,
    surfaceMuted: ColorTokens.surfaceMuted,
    onSurface: ColorTokens.onSurface,
    onSurfaceMuted: ColorTokens.onSurfaceMuted,
    accent: ColorTokens.accent,
    error: ColorTokens.error,
    outline: ColorTokens.outline,
    shadow: ColorTokens.shadow,
    noteColors: ColorTokens.noteColors,
  );
}

@immutable
class FloteSpacing {
  const FloteSpacing({
    required this.xs,
    required this.sm,
    required this.md,
    required this.lg,
    required this.xl,
    required this.xxl,
  });

  final double xs;
  final double sm;
  final double md;
  final double lg;
  final double xl;
  final double xxl;

  static const FloteSpacing standard = FloteSpacing(
    xs: SpacingTokens.xs,
    sm: SpacingTokens.sm,
    md: SpacingTokens.md,
    lg: SpacingTokens.lg,
    xl: SpacingTokens.xl,
    xxl: SpacingTokens.xxl,
  );
}

@immutable
class FloteRadius {
  const FloteRadius({
    required this.small,
    required this.medium,
    required this.large,
    required this.pill,
  });

  final double small;
  final double medium;
  final double large;
  final double pill;

  static const FloteRadius standard = FloteRadius(
    small: RadiusTokens.small,
    medium: RadiusTokens.medium,
    large: RadiusTokens.large,
    pill: RadiusTokens.pill,
  );
}

@immutable
class FloteTypography {
  const FloteTypography({
    required this.caption,
    required this.body,
    required this.bodyBold,
    required this.heading,
    required this.display,
  });

  final TextStyle caption;
  final TextStyle body;
  final TextStyle bodyBold;
  final TextStyle heading;
  final TextStyle display;

  static const FloteTypography standard = FloteTypography(
    caption: TypographyTokens.caption,
    body: TypographyTokens.body,
    bodyBold: TypographyTokens.bodyBold,
    heading: TypographyTokens.heading,
    display: TypographyTokens.display,
  );
}

/// `Theme.of(context).floteTheme` で参照できる拡張プロパティ。
///
/// ThemeExtension が未注入の場合は `FloteTheme.standard` にフォールバック。
extension FloteThemeExtension on ThemeData {
  FloteTheme get floteTheme => extension<FloteTheme>() ?? FloteTheme.standard;
}
