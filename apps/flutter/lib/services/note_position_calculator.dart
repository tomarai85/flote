// Phase 2c 修正 1: 新規ノートの出現位置ロジック (SwiftUI 踏襲)。
//
// SwiftUI 実装 `NoteManager.swift` createNote L47-61:
//   let screen = NSScreen.main?.visibleFrame ?? ...
//   let centerX = screen.midX - GoldenRatio.medium.width / 2   // 160/2 = 80
//   let centerY = screen.midY - GoldenRatio.medium.height / 2  // 120/2 = 60
//   let jitterX = CGFloat.random(in: -60...60)
//   let jitterY = CGFloat.random(in: -40...40)
//   position: CGPoint(x: centerX + jitterX, y: centerY + jitterY)
//
// Flutter 側の再現:
//   - screen size の取得は `window_manager.getPrimaryDisplay()` 経由 (呼び出し側で取得し、
//     rect を渡す。provider 層を platform 依存から切り離す)。
//   - ジッター範囲は SwiftUI と同じ ±60 / ±40。
//   - テスト時は Random を差し替え可能にする (RandomLike コールバック)。
//
// macOS / Windows ともに、座標系は「スクリーン左上を (0,0) とし、右下へ向かって正」。
// SwiftUI の visibleFrame は AppKit 座標 (左下原点) だが、position: は `window_manager`
// 経由で setFrame する際に Flutter 側は top-left origin を使うので、そのまま動く。
//
// NoteWindowManager.setFrame は (left, top, width, height) を取る。

import 'dart:math' as math;
import 'dart:ui';

import '../theme/tokens.dart';

/// テスト差替え用の乱数関数 (0.0 <= r < 1.0)。
typedef RandomDouble = double Function();

/// 新規ノートの出現位置を計算する。
///
/// [visibleFrame] は画面の可視領域 (メニューバー/タスクバーを除いた矩形)。
/// 左上 (left, top) と size で与える。通常は `getPrimaryDisplay().visibleSize`
/// と `visiblePosition` を合成したもの。
///
/// [noteSize] は SwiftUI `GoldenRatio.medium` (160x120) 相当。
/// 省略時は DimensionTokens.noteFixedWidth / noteExpandedHeight を使う。
///
/// [random] は 0.0-1.0 の一様乱数。省略時は `math.Random` を使う。
/// テストで固定値を入れたい場合に差し替える。
///
/// SwiftUI と同じジッター振幅:
/// - X: ±60 px
/// - Y: ±40 px
///
/// 戻り値: (left, top) 座標の Offset。
Offset calculateNewNotePosition({
  required Rect visibleFrame,
  Size noteSize = const Size(
    DimensionTokens.noteFixedWidth,
    DimensionTokens.noteExpandedHeight,
  ),
  RandomDouble? random,
}) {
  final rng = random ?? _defaultRandom;

  final centerX = visibleFrame.left + visibleFrame.width / 2 - noteSize.width / 2;
  final centerY = visibleFrame.top + visibleFrame.height / 2 - noteSize.height / 2;

  // SwiftUI: CGFloat.random(in: -60...60) は閉区間の一様乱数。
  // rng() は [0.0, 1.0) なので、-60 + 120 * r で -60..60 に写像 (上限は 60 含まずだが実用上差分なし)。
  final jitterX = -60.0 + 120.0 * rng();
  final jitterY = -40.0 + 80.0 * rng();

  return Offset(centerX + jitterX, centerY + jitterY);
}

/// visibleFrame の補正: size / position が取れない環境 (ヘッドレステスト等) 用のフォールバック。
/// デフォルトで 1440x900 の画面を想定した中央 rect を返す。
Rect defaultVisibleFrame() => const Rect.fromLTWH(0, 0, 1440, 900);

final _sharedRandom = math.Random();

double _defaultRandom() => _sharedRandom.nextDouble();
