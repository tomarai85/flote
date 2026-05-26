// Phase 2 視覚移植: SwiftUI `MiniNoteView.swift` に合わせた mini 状態。
//
// SwiftUI 実装要素 (既存 Swift コードから抽出):
// - ZStack + Circle fill accentColor (accentColor = colorTheme.toolbarColor)
// - shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
// - frame(width: 36, height: 36)
// - 本文先頭 1 文字: font .system(size: 16, weight: .semibold, design: .rounded)
//   foregroundColor(.primary.opacity(0.7))
// - 空のとき: Image(systemName: "note.text") font 14 medium、.primary.opacity(0.5)
//   Flutter では対応する Icons.sticky_note_2_outlined を使う (見た目近似)。
// - onTapGesture: PanelManager.shared.toggleMini(noteID) → Flutter では expanded 戻り

import 'package:flutter/material.dart';

import '../../../models/note_color_theme.dart';
import '../../../models/sticky_note.dart';
import '../../../models/stow_state.dart';
import '../../../theme/tokens.dart';

class NoteMiniView extends StatelessWidget {
  const NoteMiniView({
    super.key,
    required this.note,
    required this.onStowStateChange,
  });

  final StickyNote note;
  final void Function(StowState next) onStowStateChange;

  @override
  Widget build(BuildContext context) {
    final firstCharacter = _firstCharacter(note.text);
    final accent = note.colorTheme.toolbar;

    // SwiftUI: Color.primary.opacity はシステム primary テキスト色。
    // Flutter では ThemeData.textTheme bodyMedium の color (= onSurface) をベースに
    // 0.7 / 0.5 で減衰させる。ノート色テーマの textColor を使うと
    // 濃すぎて SwiftUI のトーンと異なるため onSurface (1C1C1E 系) を採用。
    const primary = ColorTokens.onSurface;

    return GestureDetector(
      onTap: () => onStowStateChange(StowState.expanded),
      onLongPress: () => onStowStateChange(StowState.rolledUp),
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: 'クリックで展開 / 長押しで巻物化',
        child: SizedBox(
          width: DimensionTokens.noteMiniSize,
          height: DimensionTokens.noteMiniSize,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
              boxShadow: [
                // SwiftUI: shadow radius 3, y 1, opacity 0.2
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Center(
              child: firstCharacter.isEmpty
                  ? Icon(
                      // note.text アイコン (SwiftUI) の Flutter 近似
                      Icons.sticky_note_2_outlined,
                      size: 14,
                      color: primary.withValues(alpha: 0.5),
                    )
                  : Text(
                      firstCharacter,
                      // SwiftUI: font system 16 semibold rounded
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: primary.withValues(alpha: 0.7),
                        // rounded design の Flutter 再現はフォント側で行う (近似)
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 本文の先頭 1 グリフ (UTF-16 サロゲートペア対応)。空白/改行はスキップ。
  static String _firstCharacter(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final firstRune = trimmed.runes.first;
    return String.fromCharCode(firstRune);
  }
}
