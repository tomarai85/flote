// Phase 2 (Sprint 3 Feature 3.3 継続): rolledUp 状態はフラット 26px 薄型バー。
//
// SwiftUI 版 `PaperCurlView.swift` の 3D paper curl は OUT OF SCOPE。
// Phase 2 では SwiftUI のトーン (角丸 12、toolbarColor 背景) に見た目だけ近づけつつ、
// フラットバー実装を維持する。
//
// - 幅は expanded と同じ (ウィンドウ側で制御、160px 固定)
// - 高さ 26px (SwiftUI と同じ)
// - タイトル (rolledTitle or text 先頭 12 文字) を中央に表示
// - ダブルクリックで expanded に戻る
// - トグルボタン (右端) で巻物 / mini の直接切替 (Feature 3.5 の対称性要件)

import 'package:flutter/material.dart';

import '../../../models/note_color_theme.dart';
import '../../../models/sticky_note.dart';
import '../../../models/stow_state.dart';
import '../../../theme/tokens.dart';

class NoteRolledUpView extends StatelessWidget {
  const NoteRolledUpView({
    super.key,
    required this.note,
    required this.onStowStateChange,
  });

  final StickyNote note;
  final void Function(StowState next) onStowStateChange;

  @override
  Widget build(BuildContext context) {
    final title = _displayTitle(note);
    final toolbar = note.colorTheme.toolbar;
    final textColor = note.colorTheme.textColor;

    return GestureDetector(
      onDoubleTap: () => onStowStateChange(StowState.expanded),
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 26,
        decoration: BoxDecoration(
          color: toolbar,
          // Phase 2: expanded と同じ 12 continuous で角を揃える。
          borderRadius: BorderRadius.circular(RadiusTokens.large),
        ),
        padding: const EdgeInsets.symmetric(horizontal: SpacingTokens.sm),
        child: Row(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TypographyTokens.caption.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 20,
              height: 20,
              child: IconButton(
                tooltip: 'mini 化',
                iconSize: 12,
                padding: EdgeInsets.zero,
                onPressed: () => onStowStateChange(StowState.mini),
                icon: Icon(Icons.circle_outlined, color: textColor),
              ),
            ),
            SizedBox(
              width: 20,
              height: 20,
              child: IconButton(
                tooltip: '展開',
                iconSize: 12,
                padding: EdgeInsets.zero,
                onPressed: () => onStowStateChange(StowState.expanded),
                icon: Icon(Icons.unfold_more, color: textColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// rolledTitle 優先、なければ text 先頭 12 文字 (grapheme cluster 簡易版)。
  /// 完全な grapheme 分割は characters パッケージが必要だが MVP では rune 単位。
  static String _displayTitle(StickyNote note) {
    if (note.rolledTitle.isNotEmpty) {
      return note.rolledTitle;
    }
    if (note.text.isEmpty) {
      return '(空のメモ)';
    }
    if (note.text.length <= 12) {
      return note.text;
    }
    return '${note.text.substring(0, 12)}...';
  }
}
