// 連打ガード state (Sprint 3 Feature 3.5)。
//
// サブウィンドウ内で stowState 遷移中にユーザーが別ボタンを連打しても
// 複数回の遷移が走らないように、ノート ID ごとに遷移中フラグを保持する。
//
// AnimatedContainer のアニメーション時間 (150-300ms) + ウィンドウリサイズの
// round-trip を考慮し、既定 350ms ガードする。

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// ノート ID -> 遷移開始時刻 (microseconds)。進行中でない場合は null / キー無し。
/// 350ms を過ぎたら自動的に「進行中ではない」とみなす。
final noteTransitionStartProvider =
    StateNotifierProvider<NoteTransitionStateNotifier, Map<String, int>>((ref) {
      return NoteTransitionStateNotifier();
    });

class NoteTransitionStateNotifier extends StateNotifier<Map<String, int>> {
  NoteTransitionStateNotifier() : super(const <String, int>{});

  /// 既定の連打ガード duration。AnimatedContainer の duration と合わせる。
  static const Duration guardDuration = Duration(milliseconds: 350);

  /// noteId が現在遷移中か判定する。経過 guardDuration を過ぎていれば false 扱い。
  bool isTransitioning(String noteId) {
    final started = state[noteId];
    if (started == null) {
      return false;
    }
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final elapsedUs = nowUs - started;
    if (elapsedUs >= guardDuration.inMicroseconds) {
      // 期限切れは掃除する (副作用だが UX 的に許容)。
      state = {...state}..remove(noteId);
      return false;
    }
    return true;
  }

  /// 遷移を開始する。既に進行中なら false を返し、呼び出し側は遷移をスキップする。
  bool beginTransition(String noteId) {
    if (isTransitioning(noteId)) {
      return false;
    }
    state = {...state, noteId: DateTime.now().microsecondsSinceEpoch};
    return true;
  }

  /// 遷移を明示的に完了させる。
  void endTransition(String noteId) {
    if (!state.containsKey(noteId)) {
      return;
    }
    state = {...state}..remove(noteId);
  }
}
