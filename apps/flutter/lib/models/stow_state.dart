/// 付箋の表示状態。
enum StowState {
  /// 通常編集モード (expanded)。
  expanded,

  /// 巻物状の薄型バー (rolledUp)。高さ 26px、タイトル中央表示。
  rolledUp,

  /// 円形 mini。48x48px、先頭 1 文字表示。
  mini,
}

StowState parseStowState(String name) {
  for (final state in StowState.values) {
    if (state.name == name) {
      return state;
    }
  }
  return StowState.expanded;
}
