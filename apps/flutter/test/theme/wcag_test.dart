import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/theme/wcag.dart';

void main() {
  test('白背景と黒文字は高コントラストになる', () {
    final ratio = contrastRatio(
      const Color(0xFF000000),
      const Color(0xFFFFFFFF),
    );

    expect(ratio, greaterThan(20));
  });

  test('白背景と白文字は WCAG AA を満たさない', () {
    final ratio = contrastRatio(
      const Color(0xFFFFFFFF),
      const Color(0xFFFFFFFF),
    );

    expect(ratio, closeTo(1, 0.01));
    expect(
      meetsWcagAA(const Color(0xFFFFFFFF), const Color(0xFFFFFFFF)),
      isFalse,
    );
  });

  test('bestForegroundFor は背景の明暗に応じて黒白を選ぶ', () {
    final lightBackground = const Color(0xFFFFF4B0);
    final darkBackground = const Color(0xFF1C1C1E);

    expect(bestForegroundFor(lightBackground), const Color(0xFF1C1C1E));
    expect(bestForegroundFor(darkBackground), const Color(0xFFFFFFFF));
  });

  test('11 色のノート背景すべてで WCAG AA を満たす前景色を返す (Phase 2)', () {
    for (final theme in NoteColorTheme.values) {
      final foreground = bestForegroundFor(theme.background);
      expect(
        meetsWcagAA(foreground, theme.background),
        isTrue,
        reason: '${theme.name} は WCAG AA を満たす必要があります',
      );
    }
  });
}
