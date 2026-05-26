// Phase 2c 修正 3: SwiftUI NoteView.swift topBar (L208-319) を Flutter に移植。
//
// SwiftUI の構造:
//   VStack(spacing: 2) {
//     HStack(spacing: 0) {       // Row 1: 4 icons 等間隔
//       Spacer,
//       Button(copy, doc.on.doc, 24x22, opacity 0.4),
//       Spacer,
//       Button(AI sort, wand.and.stars, 24x22, disabled if empty),
//       Spacer,
//       Button(archive, archivebox, 24x22, opacity 0.4),
//       Spacer,
//       Button(rollUp, chevron.up, 24x22, opacity 0.4),
//       Spacer,
//     }.frame(height: 22).padding(.horizontal, 4),
//
//     HStack {                    // Row 2: Organize pill, 右寄せ
//       Spacer,
//       OrganizeButton (背景 toolbarColor.opacity(0.55), cornerRadius 5,
//                       minWidth 78, font 10 medium, padding h7 v3,
//                       hover で 0.9, disabled if text empty)
//       .padding(.trailing, 6)
//     }
//   }
//
// アイコン色: Color(red: 0.22, green: 0.18, blue: 0.14) opacity 0.4
//   = RGB(56, 46, 36), alpha 0.4
//
// B/I/U/S ハイライト文字色ノート色 picker は SwiftUI NoteToolbar.swift に存在するが、
// 実際には NoteView のどこからも呼ばれていない dead code のため、Flutter 版でも
// 同じく削除する (top_bar は 4 icons + Organize のみ)。

import 'package:flutter/material.dart';

import '../../../models/note_color_theme.dart';

typedef TopBarAction = Future<void> Function();
typedef TopBarSyncAction = void Function();

/// SwiftUI と揃えるアイコン共通色。
/// `Color(red: 0.22, green: 0.18, blue: 0.14)` = RGB(56, 46, 36)。
const Color kTopBarIconBaseColor = Color.fromRGBO(56, 46, 36, 1.0);

/// SwiftUI 4 icons 相当の共通 opacity。
const double kTopBarIconDefaultOpacity = 0.4;

/// Organize pill の disabled 時透明度。
const double kOrganizeDisabledOpacity = 0.35;

/// Expanded ノートの topBar (SwiftUI 踏襲).
///
/// 2 段構成:
/// - Row 1: 4 icons (Copy / AI Sort / Archive / RollUp) 等間隔
/// - Row 2: Organize pill 右寄せ
///
/// Row 1 の各 Button は:
///   - 24 x 22 (SwiftUI `.frame(width: 24, height: 22)`)
///   - アイコンサイズ 10 (SwiftUI `.font(.system(size: 10, weight: .semibold))`)
///   - 色 = kTopBarIconBaseColor with opacity 0.4
///
/// Organize pill:
///   - 背景: note の toolbarColor を opacity 0.55 (hover で 0.9)
///   - 枠: cornerRadius 5 continuous
///   - padding: horizontal 7, vertical 3
///   - minWidth 78
///   - text "Organize" + icon wand.and.stars (Icons.auto_awesome)
///   - font: 10 medium
///   - 色 = kTopBarIconBaseColor with opacity 0.6 (hover で 0.9)
///   - disabled: text が空の時。loading 時は progress indicator を表示。
class NoteTopBar extends StatefulWidget {
  const NoteTopBar({
    super.key,
    required this.toolbarColor,
    required this.isTextEmpty,
    this.onCopy,
    this.onAISort,
    this.onArchive,
    this.onRollUp,
    this.onOrganize,
    this.onCancelOrganize,
    this.isOrganizing = false,
    this.isAISorting = false,
    this.colorTheme,
  });

  /// Row 2 の Organize pill 背景色。ノート色テーマの toolbarColor。
  final Color toolbarColor;

  /// Organize pill が enabled かを判定する。true の時は disabled。
  final bool isTextEmpty;

  /// AI Sort 実行中フラグ (progress indicator 用)。
  final bool isAISorting;

  /// Organize 実行中フラグ (pill の文言が "Organizing" に、progress indicator 表示)。
  final bool isOrganizing;

  /// Copy ボタン (省略時は非表示ではなく、無効ボタンとして表示)。
  final TopBarAction? onCopy;

  /// AI Sort ボタン。省略時は null で disabled ではなく非表示にせず、
  /// onPressed=null の「押せないボタン」として描画する。
  final TopBarAction? onAISort;

  /// Archive (閉じる相当) ボタン。
  final TopBarAction? onArchive;

  /// RollUp (巻物化) ボタン。
  final TopBarSyncAction? onRollUp;

  /// Organize pill ボタン (onOrganize が null なら常に disabled)。
  final TopBarAction? onOrganize;

  /// M0 audit Wave 4 (138s UX): Organize 実行中に表示する cancel ボタンの
  /// callback。null なら cancel ボタン非表示 (互換: 旧 caller は cancel 機能なし)。
  /// isOrganizing && onCancelOrganize != null の時のみ pill 左隣に X icon 表示。
  final TopBarSyncAction? onCancelOrganize;

  /// 参考情報 (未使用だが将来の Phase 拡張で使う可能性)。
  final NoteColorTheme? colorTheme;

  @override
  State<NoteTopBar> createState() => _NoteTopBarState();
}

class _NoteTopBarState extends State<NoteTopBar> {
  bool _isHoveringOrganize = false;
  bool _showCopiedToast = false;

  Future<void> _handleCopy() async {
    final action = widget.onCopy;
    if (action == null) return;
    try {
      await action();
    } catch (error) {
      debugPrint('NoteTopBar.onCopy failed: $error');
    }
    if (!mounted) return;
    setState(() => _showCopiedToast = true);
    // SwiftUI と同じく 1.2 秒後にチェックマーク解除。
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _showCopiedToast = false);
  }

  @override
  Widget build(BuildContext context) {
    final iconColor = kTopBarIconBaseColor.withValues(
      alpha: kTopBarIconDefaultOpacity,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // --- Row 1: 4 icons ---
        SizedBox(
          height: 22,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                const Spacer(),
                _TopBarIconButton(
                  tooltip: _showCopiedToast ? 'Copied!' : 'Copy text',
                  icon: _showCopiedToast ? Icons.check : Icons.copy,
                  color: _showCopiedToast
                      ? kTopBarIconBaseColor.withValues(alpha: 0.8)
                      : iconColor,
                  onPressed: widget.onCopy == null ? null : _handleCopy,
                ),
                const Spacer(),
                _TopBarIconButton(
                  tooltip: 'AI sort: let AI pick the best group',
                  icon: Icons.auto_awesome,
                  color: kTopBarIconBaseColor.withValues(
                    alpha: widget.isAISorting ? 0.7 : 0.45,
                  ),
                  isLoading: widget.isAISorting,
                  onPressed: (widget.onAISort == null ||
                          widget.isAISorting ||
                          widget.isTextEmpty)
                      ? null
                      : widget.onAISort,
                ),
                const Spacer(),
                _TopBarIconButton(
                  tooltip: 'Archive — close panel, note stays in Groups',
                  icon: Icons.inventory_2_outlined,
                  color: iconColor,
                  onPressed: widget.onArchive,
                ),
                const Spacer(),
                _TopBarIconButton(
                  tooltip: 'Roll up',
                  icon: Icons.keyboard_arrow_up,
                  color: iconColor,
                  onPressed: widget.onRollUp == null
                      ? null
                      : () async {
                          widget.onRollUp!();
                        },
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 2),
        // --- Row 2: Organize pill (右寄せ) ---
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Row(
            children: [
              const Spacer(),
              // M0 audit Wave 4: Organize 中は左隣に cancel (X) icon 表示。
              // 押すと organize_runner.cancel() 経由で進行中 retry を断ち切る。
              if (widget.isOrganizing && widget.onCancelOrganize != null) ...[
                _TopBarIconButton(
                  tooltip: 'Organize をキャンセル',
                  icon: Icons.close,
                  color: kTopBarIconBaseColor.withValues(alpha: 0.7),
                  // sync void → async void wrap (TopBarAction signature 合せ)。
                  onPressed: () async {
                    widget.onCancelOrganize!();
                  },
                ),
                const SizedBox(width: 4),
              ],
              _OrganizePill(
                toolbarColor: widget.toolbarColor,
                isHovering: _isHoveringOrganize,
                isOrganizing: widget.isOrganizing,
                isEnabled: !widget.isOrganizing &&
                    !widget.isTextEmpty &&
                    widget.onOrganize != null,
                onHoverChange: (hovering) {
                  if (!mounted) return;
                  setState(() => _isHoveringOrganize = hovering);
                },
                onPressed: widget.onOrganize,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TopBarIconButton extends StatelessWidget {
  const _TopBarIconButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.isLoading = false,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final bool isLoading;
  final TopBarAction? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 22,
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed == null
                ? null
                : () async {
                    try {
                      await onPressed!();
                    } catch (error) {
                      debugPrint('NoteTopBar action failed: $error');
                    }
                  },
            borderRadius: BorderRadius.circular(4),
            child: Center(
              child: isLoading
                  ? SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: color,
                      ),
                    )
                  : Icon(icon, size: 10, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrganizePill extends StatelessWidget {
  const _OrganizePill({
    required this.toolbarColor,
    required this.isHovering,
    required this.isOrganizing,
    required this.isEnabled,
    required this.onHoverChange,
    required this.onPressed,
  });

  final Color toolbarColor;
  final bool isHovering;
  final bool isOrganizing;
  final bool isEnabled;
  final ValueChanged<bool> onHoverChange;
  final TopBarAction? onPressed;

  @override
  Widget build(BuildContext context) {
    final effectiveOpacity = !isEnabled
        ? kOrganizeDisabledOpacity
        : (isHovering ? 0.9 : 0.55);

    final foregroundOpacity =
        !isEnabled ? 0.35 : (isHovering ? 0.9 : 0.6);

    final foregroundColor =
        kTopBarIconBaseColor.withValues(alpha: foregroundOpacity);

    return MouseRegion(
      cursor: isEnabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => onHoverChange(true),
      onExit: (_) => onHoverChange(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        constraints: const BoxConstraints(minWidth: 78),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: toolbarColor.withValues(alpha: effectiveOpacity),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: isEnabled
                ? () async {
                    try {
                      await onPressed?.call();
                    } catch (error) {
                      debugPrint('OrganizePill onPressed failed: $error');
                    }
                  }
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: Center(
                    child: isOrganizing
                        ? SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: foregroundColor,
                            ),
                          )
                        : Icon(
                            Icons.auto_awesome,
                            size: 10,
                            color: foregroundColor,
                          ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  isOrganizing ? 'Organizing' : 'Organize',
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
