// Phase 2 視覚移植: pickAvailableNoteColor と 11 色 NoteColorTheme を検証。

import 'dart:math' as math;

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pickAvailableNoteColor は未使用色を返す', () {
    final used = <NoteColorTheme>{
      NoteColorTheme.yellow,
      NoteColorTheme.pink,
      NoteColorTheme.blue,
    };
    // randomInt(残り 8 個のうち 0) は最初の未使用色
    final picked = pickAvailableNoteColor(used, randomInt: (_) => 0);
    expect(used.contains(picked), isFalse);
    // Phase 2: 11 色になり残り 8 色のいずれか
    expect(
      NoteColorTheme.values.where((c) => !used.contains(c)).toList(),
      contains(picked),
    );
  });

  test('pickAvailableNoteColor は全色使用済みなら全色から返す', () {
    final all = NoteColorTheme.values.toSet();
    final picked = pickAvailableNoteColor(all, randomInt: (_) => 0);
    expect(NoteColorTheme.values, contains(picked));
  });

  test('pickAvailableNoteColor は空使用リストでも落ちない', () {
    final picked = pickAvailableNoteColor(
      const <NoteColorTheme>[],
      randomInt: (_) => 2,
    );
    // 候補 11 個のうち index 2 = blue (SwiftUI と同じ順序)
    expect(picked, NoteColorTheme.blue);
  });

  test('Phase 2: NoteColorTheme は 11 色定義される', () {
    expect(NoteColorTheme.values.length, 11);
    // SwiftUI NoteColorTheme と同じ順序
    expect(NoteColorTheme.values.first, NoteColorTheme.yellow);
    expect(NoteColorTheme.values.last, NoteColorTheme.sky);
  });

  test('全 11 色に日本語ラベルが定義される', () {
    for (final theme in NoteColorTheme.values) {
      expect(theme.displayName, isNotEmpty);
    }
  });

  test('全 11 色の textColor は WCAG AA を満たす (contrast >= 4.5:1)', () {
    // Phase 2: SwiftUI 側で事前計算済みの exact 色を使う。
    // 黒/白の二択ではなく、背景ごとに調整された暗色 (濃茶/濃紺/濃紫等)。
    // ここでは WCAG AA 準拠のみ検証する。
    for (final theme in NoteColorTheme.values) {
      final fg = theme.textColor;
      final bg = theme.background;
      final ratio = _contrastRatio(fg, bg);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            '${theme.name} は WCAG AA を満たす必要がある (actual=$ratio)',
      );
    }
  });
}

double _linearizeChannel(double channel) {
  if (channel <= 0.03928) {
    return channel / 12.92;
  }
  return math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}

double _relativeLuminance(Color c) {
  return 0.2126 * _linearizeChannel(c.r) +
      0.7152 * _linearizeChannel(c.g) +
      0.0722 * _linearizeChannel(c.b);
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = la >= lb ? la : lb;
  final darker = la < lb ? la : lb;
  return (lighter + 0.05) / (darker + 0.05);
}
