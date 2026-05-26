// Phase 2 視覚移植 + Phase 2c 修正 3: SwiftUI `NoteView.swift` expanded レイアウト踏襲。
//
// SwiftUI 実装要素:
// - 外枠 .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
// - VStack(spacing: 0): topBar + 本文エディタ + errorBanner
// - 背景色 = colorTheme.backgroundColor
// - topBar は NoteTopBar (Phase 2c: Copy / AI Sort / Archive / RollUp + Organize pill)
// - 本文は .padding(.horizontal, 8) .padding(.top, 2) .padding(.bottom, 6)
//
// Phase 2c: 旧実装 (NoteToolbar = B/I/U/S + カラー picker + 削除 + 閉じる等多数) を
// SwiftUI の topBar に合わせて整理。B/I/U/S / ハイライト / 文字色 / shapes は
// SwiftUI 側でも dead code だったため Flutter でも UI から除外する。
// (色変更や削除は別経路 = 右クリック or 設定画面に移動 or MVP では非表示)。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/note_color_theme.dart';
import '../../../models/sticky_note.dart';
import '../../../models/stow_state.dart';
import '../../../providers/organize_runner.dart';
import '../../../theme/tokens.dart';
import '../rich_text_editor.dart';
import '../toolbar/top_bar.dart';

/// ツールバーのアクションコールバック。
typedef StowStateCallback = void Function(StowState next);
typedef VoidAction = Future<void> Function();

class NoteExpandedView extends ConsumerStatefulWidget {
  const NoteExpandedView({
    super.key,
    required this.note,
    required this.onStowStateChange,
    required this.onRequestClose,
    required this.onRichTextChanged,
    required this.onColorThemeChanged,
    required this.onDeleteRequested,
    this.onOrganize,
    this.onUndoOrganize,
  });

  final StickyNote note;
  final StowStateCallback onStowStateChange;
  final VoidAction onRequestClose;

  /// rich text Delta JSON が更新された時に呼ぶ。plainText は第 2 引数で渡し、
  /// NoteWindowNotifier.updateRichText(richText, plainText: ...) で同時更新する。
  final void Function(String richTextJson, String plainText) onRichTextChanged;

  /// ノートカラーテーマ切替。
  final void Function(NoteColorTheme next) onColorThemeChanged;

  /// 削除要求。空ノートかどうかは呼び出し側で判定して確認ダイアログを出す。
  final VoidAction onDeleteRequested;

  /// Sprint 5 Feature 5.1: AI 整理実行。
  final VoidAction? onOrganize;

  /// Sprint 5 Feature 5.1: AI 整理の巻戻し (Ctrl+Z/⌘Z) 相当。
  /// 省略時は Ctrl+Z による undo は有効にならない。
  final VoidAction? onUndoOrganize;

  @override
  ConsumerState<NoteExpandedView> createState() => _NoteExpandedViewState();
}

class _NoteExpandedViewState extends ConsumerState<NoteExpandedView> {
  late final QuillController _quillController;

  @override
  void initState() {
    super.initState();
    _quillController = QuillController.basic();
  }

  @override
  void dispose() {
    _quillController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final bg = note.colorTheme.background;
    final toolbar = note.colorTheme.toolbar;
    final textColor = note.colorTheme.textColor;
    final hintColor = textColor.withValues(alpha: 0.45);

    // Phase 2: 外枠の角丸 12px continuous (SwiftUI 踏襲)。
    // cornerRadius.large = 12 を使い、DecoratedBox + ClipRRect で安定させる。
    final outerRadius =
        BorderRadius.circular(RadiusTokens.large);

    // Phase 2c: note.text が trim して空か (Organize / AI sort の disabled 判定に使う)。
    final isTextEmpty = note.text.trim().isEmpty;

    return ClipRRect(
      borderRadius: outerRadius,
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: outerRadius,
        ),
        child: CallbackShortcuts(
          bindings: _buildShortcutBindings(note.id),
          child: Focus(
            // Organize undo ショートカットを受け取るため、明示的にフォーカスを掴む。
            // ただし descendants (QuillEditor) もフォーカスを取れるようにしておく。
            autofocus: false,
            canRequestFocus: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Phase 2c: SwiftUI topBar 踏襲 (Copy + AI Sort + Archive + RollUp + Organize)。
                // M0 audit Wave 4 (138s UX): isOrganizing と onCancelOrganize を
                // organizeRunnerProvider から取得して NoteTopBar に渡す。pill が
                // "Organizing..." 表示中に左隣に X icon (cancel) が出る。
                NoteTopBar(
                  toolbarColor: toolbar,
                  isTextEmpty: isTextEmpty,
                  colorTheme: note.colorTheme,
                  isOrganizing: ref.watch(organizeRunnerProvider).isRunning,
                  onCopy: () => _handleCopy(note),
                  // AI Sort は現 MVP ではメインの AI Sort (Batch Classify) 経路とは
                  // 別の「このノート 1 件だけを既存 Group に分類する」機能。
                  // 実装が未接続のため、onAISort は onOrganize と同じ AI 整理を
                  // 流用する (SwiftUI 版に近い挙動)。将来 1 件分類の実装が入ったら差替え。
                  onAISort: widget.onOrganize,
                  onArchive: widget.onRequestClose,
                  onRollUp: () =>
                      widget.onStowStateChange(StowState.rolledUp),
                  onOrganize: widget.onOrganize,
                  onCancelOrganize: () =>
                      ref.read(organizeRunnerProvider.notifier).cancel(),
                ),
                Expanded(
                  child: Padding(
                    // SwiftUI: .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 6)
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                    child: DefaultTextStyle(
                      style: TypographyTokens.body.copyWith(color: textColor),
                      child: NoteRichTextEditor(
                        note: note,
                        textColor: textColor,
                        hintColor: hintColor,
                        externalController: _quillController,
                        onRichTextChanged: (richTextJson) {
                          final plainText = richTextToPlainText(richTextJson);
                          widget.onRichTextChanged(richTextJson, plainText);
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Phase 2c: Copy ボタン押下で plainText をクリップボードに載せる。
  /// SwiftUI 版は rich text (RTF) と plain 両方をペーストボードに載せているが、
  /// Flutter の標準 Clipboard では plain のみ。Rich copy は将来拡張とする。
  Future<void> _handleCopy(StickyNote note) async {
    final plain = note.text.isNotEmpty
        ? note.text
        : richTextToPlainText(note.richText);
    if (plain.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: plain));
  }

  /// Sprint 5 Feature 5.1: Organize Undo のキーバインド。
  /// Organize undo stack にエントリがある場合に限り ⌘Z / Ctrl+Z を
  /// Organize 巻戻しにフックする。スタックが無ければ Quill のデフォルト undo に
  /// 流れる (CallbackShortcuts で発火せず、下位の TextField デフォルト処理に降りる)。
  Map<ShortcutActivator, VoidCallback> _buildShortcutBindings(String noteId) {
    final undoAction = widget.onUndoOrganize;
    if (undoAction == null) {
      return const {};
    }
    final runner = ref.read(organizeRunnerProvider.notifier);
    if (!runner.canUndoFor(noteId)) {
      return const {};
    }
    return <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
          () async => undoAction(),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
          () async => undoAction(),
    };
  }
}
