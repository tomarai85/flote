// Phase 2c 修正 1 テスト: 新規ノート位置計算。
//
// SwiftUI NoteManager.swift の画面中央 + ジッター配置ロジックを Flutter で再現
// した calculateNewNotePosition() の挙動検証。

import 'dart:ui';

import 'package:flote_desktop/services/note_position_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('calculateNewNotePosition', () {
    const noteSize = Size(160, 120);

    test('r=0.5 (中央値) だとジッターが 0 になり、画面中央 - noteSize/2 の座標になる',
        () {
      final frame = const Rect.fromLTWH(0, 0, 1440, 900);
      final offset = calculateNewNotePosition(
        visibleFrame: frame,
        noteSize: noteSize,
        // r=0.5 → jitterX = -60 + 120*0.5 = 0、jitterY = -40 + 80*0.5 = 0
        random: () => 0.5,
      );
      // centerX = 0 + 1440/2 - 160/2 = 720 - 80 = 640
      // centerY = 0 + 900/2 - 120/2 = 450 - 60 = 390
      expect(offset.dx, 640);
      expect(offset.dy, 390);
    });

    test('r=0.0 (最小) だとジッター -60/-40、r=1.0 (最大) だとジッター +60/+40', () {
      final frame = const Rect.fromLTWH(0, 0, 1440, 900);
      final atMin = calculateNewNotePosition(
        visibleFrame: frame,
        noteSize: noteSize,
        random: () => 0.0,
      );
      expect(atMin.dx, 640 + (-60));
      expect(atMin.dy, 390 + (-40));

      final atMax = calculateNewNotePosition(
        visibleFrame: frame,
        noteSize: noteSize,
        random: () => 1.0,
      );
      expect(atMax.dx, closeTo(640 + 60, 0.0001));
      expect(atMax.dy, closeTo(390 + 40, 0.0001));
    });

    test('visibleFrame の origin が (0,0) でなくても中央が正しく計算される', () {
      // メニューバー分オフセットされた多ディスプレイ環境を模擬。
      final frame = const Rect.fromLTWH(100, 50, 1200, 800);
      final offset = calculateNewNotePosition(
        visibleFrame: frame,
        noteSize: noteSize,
        random: () => 0.5, // ジッター 0
      );
      // centerX = 100 + 600 - 80 = 620
      // centerY = 50 + 400 - 60 = 390
      expect(offset.dx, 620);
      expect(offset.dy, 390);
    });

    test('省略時 noteSize は DimensionTokens (160x120) と一致', () {
      final frame = const Rect.fromLTWH(0, 0, 1000, 800);
      final offset = calculateNewNotePosition(
        visibleFrame: frame,
        random: () => 0.5,
      );
      // centerX = 500 - 80 = 420, centerY = 400 - 60 = 340
      expect(offset.dx, 420);
      expect(offset.dy, 340);
    });

    test('複数回呼び出しで異なる座標が返る (デフォルト乱数)', () {
      final frame = const Rect.fromLTWH(0, 0, 1440, 900);
      final offsets = <Offset>[];
      for (var i = 0; i < 8; i++) {
        offsets.add(calculateNewNotePosition(
          visibleFrame: frame,
          noteSize: noteSize,
        ));
      }
      // 全て同じ座標は乱数失敗 (理論上起こるが 8 回連続はほぼゼロ)。
      final uniqueDx = offsets.map((o) => o.dx).toSet();
      expect(uniqueDx.length, greaterThan(1),
          reason: 'デフォルト乱数で複数回呼ぶと異なる座標になるはず');
    });

    test('ジッター範囲: 全ての結果が [center - 60, center + 60] x [center - 40, center + 40] に収まる',
        () {
      final frame = const Rect.fromLTWH(0, 0, 1440, 900);
      final centerX = 640.0;
      final centerY = 390.0;
      for (var i = 0; i < 100; i++) {
        final offset = calculateNewNotePosition(
          visibleFrame: frame,
          noteSize: noteSize,
        );
        expect(offset.dx, greaterThanOrEqualTo(centerX - 60 - 0.0001));
        expect(offset.dx, lessThanOrEqualTo(centerX + 60 + 0.0001));
        expect(offset.dy, greaterThanOrEqualTo(centerY - 40 - 0.0001));
        expect(offset.dy, lessThanOrEqualTo(centerY + 40 + 0.0001));
      }
    });
  });

  group('defaultVisibleFrame', () {
    test('1440x900 の fallback 矩形を返す', () {
      final f = defaultVisibleFrame();
      expect(f.left, 0);
      expect(f.top, 0);
      expect(f.width, 1440);
      expect(f.height, 900);
    });
  });
}
