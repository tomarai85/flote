// Sprint 6 Feature 6.4: FloteTheme / 各トークンのサニティテスト。
//
// 第二段階で値を差し替える際に、呼び出し側の期待値が壊れないことを保証する。

import 'package:flote_desktop/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ColorTokens', () {
    test(
      'noteColors が 11 色揃っている (SwiftUI NoteColorTheme 1:1 対応)',
      () {
        expect(ColorTokens.noteColors.length, 11);
        expect(ColorTokens.noteColors[0], ColorTokens.noteYellow);
        expect(ColorTokens.noteColors[1], ColorTokens.notePink);
        expect(ColorTokens.noteColors[2], ColorTokens.noteBlue);
        expect(ColorTokens.noteColors[3], ColorTokens.noteGreen);
        expect(ColorTokens.noteColors[4], ColorTokens.notePurple);
        expect(ColorTokens.noteColors[5], ColorTokens.noteOrange);
        expect(ColorTokens.noteColors[6], ColorTokens.noteCoral);
        expect(ColorTokens.noteColors[7], ColorTokens.noteMint);
        expect(ColorTokens.noteColors[8], ColorTokens.noteLavender);
        expect(ColorTokens.noteColors[9], ColorTokens.notePeach);
        expect(ColorTokens.noteColors[10], ColorTokens.noteSky);
      },
    );

    test('SwiftUI の exact RGB 値と一致する (抜粋)', () {
      // SwiftUI: Color(red: 1.000, green: 0.976, blue: 0.769)
      //       -> R255 G249 B196 (0.976 * 255 = 248.88 -> 249, 0.769 * 255 = 196.1)
      expect(ColorTokens.noteYellow, const Color.fromARGB(255, 255, 249, 196));
      // Color(red: 1.000, green: 0.878, blue: 0.902)
      //       -> R255 G224 B230
      expect(ColorTokens.notePink, const Color.fromARGB(255, 255, 224, 230));
      // 新規追加色も exact 値
      expect(ColorTokens.noteCoral, const Color.fromARGB(255, 255, 221, 213));
      expect(ColorTokens.noteSky, const Color.fromARGB(255, 220, 241, 255));
    });

    test('基調色が定義されている', () {
      expect(ColorTokens.surface, isA<Color>());
      expect(ColorTokens.onSurface, isA<Color>());
      expect(ColorTokens.accent, isA<Color>());
      expect(ColorTokens.error, isA<Color>());
    });
  });

  group('DimensionTokens (Phase 2)', () {
    test('ノート窓の固定サイズが SwiftUI と一致する', () {
      expect(DimensionTokens.noteFixedWidth, 160);
      expect(DimensionTokens.noteExpandedHeight, 120);
      expect(DimensionTokens.noteRolledUpHeight, 26);
      expect(DimensionTokens.noteMiniSize, 36);
    });
  });

  group('AppFontFamily (Phase 2)', () {
    test('6 フォントファミリが定義されている', () {
      expect(AppFontFamily.values.length, 6);
      expect(AppFontFamily.hiraginoSans, isNotNull);
      expect(AppFontFamily.menlo, isNotNull);
    });

    test('displayName / macosFontName / fallbackFontName が揃う', () {
      for (final family in AppFontFamily.values) {
        expect(family.displayName, isNotEmpty);
        expect(family.macosFontName, isNotEmpty);
        expect(family.fallbackFontName, isNotEmpty);
      }
    });

    test('fromName: 不明値は hiraginoSans にフォールバック', () {
      expect(AppFontFamily.fromName(null), AppFontFamily.hiraginoSans);
      expect(AppFontFamily.fromName(''), AppFontFamily.hiraginoSans);
      expect(AppFontFamily.fromName('bogus'), AppFontFamily.hiraginoSans);
      expect(AppFontFamily.fromName('menlo'), AppFontFamily.menlo);
    });
  });

  group('SpacingTokens', () {
    test('6 段階の spacing が定義されている', () {
      expect(SpacingTokens.xs, 4);
      expect(SpacingTokens.sm, 8);
      expect(SpacingTokens.md, 16);
      expect(SpacingTokens.lg, 24);
      expect(SpacingTokens.xl, 32);
      expect(SpacingTokens.xxl, 48);
    });
  });

  group('RadiusTokens', () {
    test('4 段階の radius が定義されている', () {
      expect(RadiusTokens.small, 4);
      expect(RadiusTokens.medium, 8);
      expect(RadiusTokens.large, 12);
      expect(RadiusTokens.pill, 9999);
    });
  });

  group('TypographyTokens', () {
    test('5 段階の TextStyle が定義されている', () {
      expect(TypographyTokens.caption.fontSize, 11);
      expect(TypographyTokens.body.fontSize, 13);
      expect(TypographyTokens.bodyBold.fontSize, 13);
      expect(TypographyTokens.bodyBold.fontWeight, FontWeight.w600);
      expect(TypographyTokens.heading.fontSize, 17);
      expect(TypographyTokens.display.fontSize, 28);
    });
  });

  group('FloteTheme', () {
    test('standard が全サブトークン束を持つ', () {
      final t = FloteTheme.standard;
      expect(t.colors.surface, ColorTokens.surface);
      expect(t.spacing.md, SpacingTokens.md);
      expect(t.radius.medium, RadiusTokens.medium);
      expect(t.typography.body.fontSize, TypographyTokens.body.fontSize);
    });

    test('copyWith は部分上書きできる', () {
      const customSpacing = FloteSpacing(
        xs: 2,
        sm: 4,
        md: 12,
        lg: 20,
        xl: 28,
        xxl: 40,
      );
      final t = FloteTheme.standard.copyWith(spacing: customSpacing);
      expect(t.spacing.md, 12);
      // 他のトークンは維持
      expect(t.colors.surface, ColorTokens.surface);
      expect(t.radius.medium, RadiusTokens.medium);
    });

    test('lerp はしきい値 0.5 で切り替え', () {
      const a = FloteTheme.standard;
      final b = FloteTheme.standard.copyWith(
        spacing: const FloteSpacing(
          xs: 0,
          sm: 0,
          md: 0,
          lg: 0,
          xl: 0,
          xxl: 0,
        ),
      );
      expect(a.lerp(b, 0.3).spacing.md, SpacingTokens.md);
      expect(a.lerp(b, 0.7).spacing.md, 0);
    });

    test('ThemeData に extension として注入できる', () {
      final data = ThemeData(
        extensions: const <ThemeExtension<dynamic>>[FloteTheme.standard],
      );
      final t = data.floteTheme;
      expect(t.colors.accent, ColorTokens.accent);
    });

    test('extension 未注入の ThemeData でもフォールバックする', () {
      final data = ThemeData();
      final t = data.floteTheme;
      expect(t, FloteTheme.standard);
    });
  });
}
