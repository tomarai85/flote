// Phase 2 視覚移植: SwiftUI `NoteColorTheme` と 1:1 で 11 色対応。
//
// SwiftUI 側の backgroundColor / toolbarColor / textColor は
// `StickyNote.swift` の enum NoteColorTheme で exact な sRGB 値として定義されている。
// Flutter 側もそれと同じ RGB 値を ColorTokens に保持し、getter で橋渡しする。
//
// 旧 (Sprint 4) との差分:
// - enum に 5 色追加 (coral / mint / lavender / peach / sky)
// - toolbar は「背景 * 0.88」の動的計算から ColorTokens.toolbar* 固定値へ
//   (SwiftUI のトーンを exact 合わせる必要があるため)
// - textColor も動的 bestForegroundFor 判定から ColorTokens.text* 固定値へ
//   (SwiftUI 側が事前に WCAG AA 合格を確認して選定している色を流用)

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

NoteColorTheme parseNoteColorTheme(String name) {
  for (final theme in NoteColorTheme.values) {
    if (theme.name == name) {
      return theme;
    }
  }
  return NoteColorTheme.yellow;
}

/// SwiftUI `NoteColorTheme` (11 色) と同一順序で並べる。
enum NoteColorTheme {
  yellow,
  pink,
  blue,
  green,
  purple,
  orange,
  coral,
  mint,
  lavender,
  peach,
  sky,
}

extension NoteColorThemeX on NoteColorTheme {
  /// ノート背景色。SwiftUI `NoteColorTheme.backgroundColor` と exact 一致。
  Color get background {
    switch (this) {
      case NoteColorTheme.yellow:
        return ColorTokens.noteYellow;
      case NoteColorTheme.pink:
        return ColorTokens.notePink;
      case NoteColorTheme.blue:
        return ColorTokens.noteBlue;
      case NoteColorTheme.green:
        return ColorTokens.noteGreen;
      case NoteColorTheme.purple:
        return ColorTokens.notePurple;
      case NoteColorTheme.orange:
        return ColorTokens.noteOrange;
      case NoteColorTheme.coral:
        return ColorTokens.noteCoral;
      case NoteColorTheme.mint:
        return ColorTokens.noteMint;
      case NoteColorTheme.lavender:
        return ColorTokens.noteLavender;
      case NoteColorTheme.peach:
        return ColorTokens.notePeach;
      case NoteColorTheme.sky:
        return ColorTokens.noteSky;
    }
  }

  /// ツールバー背景色。SwiftUI `NoteColorTheme.toolbarColor` と exact 一致。
  ///
  /// 旧実装は background * 0.88 の動的計算だったが、SwiftUI が事前定義した
  /// exact RGB を踏襲することで見た目を完全一致させる (Phase 2)。
  Color get toolbar {
    switch (this) {
      case NoteColorTheme.yellow:
        return ColorTokens.toolbarYellow;
      case NoteColorTheme.pink:
        return ColorTokens.toolbarPink;
      case NoteColorTheme.blue:
        return ColorTokens.toolbarBlue;
      case NoteColorTheme.green:
        return ColorTokens.toolbarGreen;
      case NoteColorTheme.purple:
        return ColorTokens.toolbarPurple;
      case NoteColorTheme.orange:
        return ColorTokens.toolbarOrange;
      case NoteColorTheme.coral:
        return ColorTokens.toolbarCoral;
      case NoteColorTheme.mint:
        return ColorTokens.toolbarMint;
      case NoteColorTheme.lavender:
        return ColorTokens.toolbarLavender;
      case NoteColorTheme.peach:
        return ColorTokens.toolbarPeach;
      case NoteColorTheme.sky:
        return ColorTokens.toolbarSky;
    }
  }

  /// 本文テキスト色。SwiftUI `NoteColorTheme.textColor` と exact 一致。
  ///
  /// SwiftUI 側で各背景に対して WCAG AA (contrast >= 4.5:1) を満たす濃色を
  /// 事前に選定済みのため、Flutter では bestForegroundFor 動的計算を使わず
  /// その値をそのまま使う (見た目の完全一致とパフォーマンス両立)。
  Color get textColor {
    switch (this) {
      case NoteColorTheme.yellow:
        return ColorTokens.textYellow;
      case NoteColorTheme.pink:
        return ColorTokens.textPink;
      case NoteColorTheme.blue:
        return ColorTokens.textBlue;
      case NoteColorTheme.green:
        return ColorTokens.textGreen;
      case NoteColorTheme.purple:
        return ColorTokens.textPurple;
      case NoteColorTheme.orange:
        return ColorTokens.textOrange;
      case NoteColorTheme.coral:
        return ColorTokens.textCoral;
      case NoteColorTheme.mint:
        return ColorTokens.textMint;
      case NoteColorTheme.lavender:
        return ColorTokens.textLavender;
      case NoteColorTheme.peach:
        return ColorTokens.textPeach;
      case NoteColorTheme.sky:
        return ColorTokens.textSky;
    }
  }

  /// ピッカー UI で表示するラベル (日本語)。
  String get displayName {
    switch (this) {
      case NoteColorTheme.yellow:
        return '黄色';
      case NoteColorTheme.pink:
        return 'ピンク';
      case NoteColorTheme.blue:
        return '青';
      case NoteColorTheme.green:
        return '緑';
      case NoteColorTheme.purple:
        return '紫';
      case NoteColorTheme.orange:
        return 'オレンジ';
      case NoteColorTheme.coral:
        return 'コーラル';
      case NoteColorTheme.mint:
        return 'ミント';
      case NoteColorTheme.lavender:
        return 'ラベンダー';
      case NoteColorTheme.peach:
        return 'ピーチ';
      case NoteColorTheme.sky:
        return 'スカイ';
    }
  }
}

/// Sprint 4 Feature 4.2: 使用中の色を避けて新規ノート色を自動選択する。
///
/// 現在開いているノートで使われている色を除外した候補からランダム選択。
/// 全色使用済みなら全色からランダム。
NoteColorTheme pickAvailableNoteColor(
  Iterable<NoteColorTheme> usedColors, {
  int Function(int max)? randomInt,
}) {
  final used = usedColors.toSet();
  final available = NoteColorTheme.values
      .where((color) => !used.contains(color))
      .toList();
  final rng = randomInt ?? _defaultRandomInt;
  if (available.isNotEmpty) {
    return available[rng(available.length)];
  }
  return NoteColorTheme.values[rng(NoteColorTheme.values.length)];
}

int _defaultRandomInt(int max) {
  // 遅延 import を避けるためここで import せず、dart:math は呼び出し側に依存。
  // シード不要のデフォルトは UIX 上でのランダム性で十分なので、
  // 複雑な乱数源は使わない (DateTime.microsecondsSinceEpoch から算出)。
  final seed = DateTime.now().microsecondsSinceEpoch;
  return (seed % max).abs();
}
