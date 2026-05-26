// ノート用サブウィンドウのルート Widget。
//
// Feature 3.2 / 3.3 / 3.4 / 3.5 を一貫して司る:
//  - note.stowState に応じて expanded / rolledUp / mini を切替
//  - 遷移は AnimatedSwitcher + AnimatedContainer (150-300ms)
//  - 連打ガード: NoteTransitionStateNotifier で 350ms ロック
//  - 閉じる (Feature 3.2 右上): isPanelOpen=false にして window close
//  - DragToMoveArea でウィンドウをドラッグ移動、WindowListener で位置保存
//  - 閉じる / 保存時にはメインへ IPC (noteWindow.panelClosed / noteWindow.noteUpdated) を送信

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/note_color_theme.dart';
import '../../models/sticky_note.dart';
import '../../models/stow_state.dart';
import '../../providers/app_settings.dart';
import '../../providers/note_window_transition.dart';
import '../../providers/organize_runner.dart';
import '../../services/note_window_manager.dart';
import '../../services/organize_service.dart';
import 'note_window_model.dart';
import 'rich_text_editor.dart';
import 'states/expanded_view.dart';
import 'states/mini_view.dart';
import 'states/rolled_up_view.dart';

/// ウィンドウ遷移アニメーション時間。spec Feature 3.5 の 150-300ms 範囲。
const Duration kNoteWindowTransitionDuration = Duration(milliseconds: 220);

/// Phase 2c 修正 2: ノートが「空」= プレーンテキストが空白のみ && richText も実質空。
///
/// 空ノートを閉じると Inbox 汚染防止のため削除経路に流す (SwiftUI
/// `NoteManager.archiveNote` の挙動踏襲)。
///
/// Top-level 関数として切り出すことで、単体テストから直接呼べる。
bool isNoteEmptyForCloseDeletion({
  required String text,
  required String richText,
}) {
  return text.trim().isEmpty && isRichTextContentEmpty(richText);
}

class NoteWindowShell extends ConsumerStatefulWidget {
  const NoteWindowShell({
    super.key,
    required this.windowController,
    this.onStowStateChanged,
    this.onPanelClosed,
    this.onDeleteConfirmed,
  });

  /// サブウィンドウ側で生成された WindowController。
  /// テスト時は null を許容し、実機と挙動を揃える。
  final WindowController? windowController;

  /// stowState が変わった後にメイン側 (NoteManager) へ通知するためのコールバック。
  /// main.dart の sub-window entry で DesktopMultiWindow.invokeMethod に接続する。
  final Future<void> Function(StowState next)? onStowStateChanged;

  /// 「閉じる」ボタン押下でウィンドウを閉じる直前に呼ばれる。
  /// 実装ではメイン側へ noteWindow.panelClosed IPC を送信する。
  final Future<void> Function()? onPanelClosed;

  /// Sprint 4 Feature 4.3: 削除要求がユーザー確認を経て確定した時にメインへ
  /// IPC で通知するためのコールバック。
  /// 本 Widget 内では確認ダイアログ表示・empty/non-empty 判定を担い、
  /// ユーザーが Delete を確定した後にこのコールバックを呼ぶ。
  final Future<void> Function()? onDeleteConfirmed;

  @override
  ConsumerState<NoteWindowShell> createState() => _NoteWindowShellState();
}

class _NoteWindowShellState extends ConsumerState<NoteWindowShell> {
  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(noteWindowNotifierProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text('ノートの読み込みに失敗: $error'),
        ),
        data: (state) => _buildStateUi(context, ref, state.note),
      ),
    );
  }

  Widget _buildStateUi(BuildContext context, WidgetRef ref, StickyNote note) {
    final child = _viewForState(note);

    // ウィンドウ全域でドラッグ移動を受け付ける (Feature 3.1)。
    // mini/rolledUp 時は子の GestureDetector が優先される挙動にする。
    final draggable = DragToMoveArea(
      child: AnimatedSize(
        duration: kNoteWindowTransitionDuration,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topLeft,
        child: AnimatedSwitcher(
          duration: kNoteWindowTransitionDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (Widget c, Animation<double> anim) {
            return FadeTransition(opacity: anim, child: c);
          },
          child: KeyedSubtree(
            key: ValueKey(note.stowState),
            child: child,
          ),
        ),
      ),
    );

    return draggable;
  }

  Widget _viewForState(StickyNote note) {
    switch (note.stowState) {
      case StowState.expanded:
        return NoteExpandedView(
          note: note,
          onStowStateChange: (next) => _requestStow(note, next),
          onRequestClose: () => _requestClose(note),
          onRichTextChanged: (richTextJson, plainText) {
            ref
                .read(noteWindowNotifierProvider.notifier)
                .updateRichText(richTextJson, plainText: plainText);
          },
          onColorThemeChanged: (next) => _requestColorTheme(note, next),
          onDeleteRequested: () => _requestDelete(note),
          onOrganize: () => _requestOrganize(note),
          onUndoOrganize: () => _requestUndoOrganize(note),
        );
      case StowState.rolledUp:
        return NoteRolledUpView(
          note: note,
          onStowStateChange: (next) => _requestStow(note, next),
        );
      case StowState.mini:
        return NoteMiniView(
          note: note,
          onStowStateChange: (next) => _requestStow(note, next),
        );
    }
  }

  /// Sprint 5 Feature 5.1: AI Organize 実行。
  /// ローディング表示 + ルーティング + 結果反映 + エラーバナー。
  Future<void> _requestOrganize(StickyNote note) async {
    final runner = ref.read(organizeRunnerProvider.notifier);
    final settings = await ref.read(appSettingsProvider.future);

    // 現在の plainText を取得する (rich_text_editor の top-level helper)。
    final plainTextBefore = note.text.isNotEmpty
        ? note.text
        : richTextToPlainText(note.richText);

    if (plainTextBefore.trim().isEmpty) {
      _showBanner('整理するテキストがありません', isError: true);
      return;
    }

    _showBanner('整理中... (Ollama or Claude)');

    final result = await runner.run(
      noteId: note.id,
      richTextBefore: note.richText,
      plainTextBefore: plainTextBefore,
      settings: settings,
      apply: (richText, plainText) async {
        await ref
            .read(noteWindowNotifierProvider.notifier)
            .updateRichText(richText, plainText: plainText);
      },
      isNoteAlive: () async {
        final snap = ref.read(noteWindowNotifierProvider).value;
        return snap != null && snap.note.id == note.id;
      },
    );

    _dismissBanner();
    switch (result) {
      case OrganizeSuccess():
        _showBanner('整理が完了しました (Ctrl+Z で元に戻せます)');
      case OrganizeFailure():
        _showBanner(
          '整理に失敗 [${result.kind.name}]: ${result.message}',
          isError: true,
        );
    }
  }

  /// Sprint 5 Feature 5.1: Organize 前の richText に戻す (⌘Z / Ctrl+Z 相当)。
  Future<void> _requestUndoOrganize(StickyNote note) async {
    final runner = ref.read(organizeRunnerProvider.notifier);
    final entry = runner.popUndo(note.id);
    if (entry == null) {
      _showBanner('元に戻せる整理履歴がありません', isError: true);
      return;
    }
    await ref.read(noteWindowNotifierProvider.notifier).updateRichText(
          entry.richTextBefore,
          plainText: entry.plainTextBefore,
        );
    _showBanner('整理前の状態に戻しました');
  }

  void _showBanner(String message, {bool isError = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      debugPrint('[note_window] banner: $message');
      return;
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: isError ? 5 : 3),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  void _dismissBanner() {
    ScaffoldMessenger.maybeOf(context)?.clearSnackBars();
  }

  /// Sprint 4 Feature 4.2: ノートカラーテーマの切替。
  /// NoteWindowNotifier に伝えるだけで save は 500ms debounce でまとまる。
  Future<void> _requestColorTheme(StickyNote note, NoteColorTheme next) async {
    if (note.colorTheme == next) {
      return;
    }
    await ref
        .read(noteWindowNotifierProvider.notifier)
        .updateColorTheme(next);
  }

  /// Sprint 4 Feature 4.3: ノート削除フロー。
  /// - 空ノート (text が空 & richText も空) は確認なしで削除 (現行踏襲)。
  /// - 非空は「削除しますか」ダイアログ → Delete (destructive) で確定。
  /// 確定後は `onDeleteConfirmed` でメインに IPC 通知、最後にウィンドウを閉じる。
  Future<void> _requestDelete(StickyNote note) async {
    final isEmpty = note.text.trim().isEmpty &&
        _isRichTextEmpty(note.richText);

    if (!isEmpty) {
      final confirmed = await _showDeleteConfirmation(context);
      if (confirmed != true) {
        return;
      }
    }

    // メイン側の NoteManager に削除通知 (IPC)。失敗しても UX を壊さない。
    try {
      await widget.onDeleteConfirmed?.call();
    } catch (error) {
      debugPrint('NoteWindowShell.onDeleteConfirmed failed: $error');
    }

    final controller = widget.windowController;
    if (controller != null) {
      try {
        await controller.close();
      } catch (error) {
        debugPrint('NoteWindowShell.close after delete failed: $error');
      }
    }
  }

  Future<bool?> _showDeleteConfirmation(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('ノートを削除しますか'),
          content: const Text('このノートの内容が失われます。履歴から復元できます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('キャンセル'),
            ),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.red.shade600,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('削除'),
            ),
          ],
        );
      },
    );
  }

  /// Sprint 4 Feature 4.3: Delta JSON が実質空か。
  /// 実体は top-level の [isRichTextContentEmpty] に委譲する (テスト容易性)。
  bool _isRichTextEmpty(String richTextJson) {
    return isRichTextContentEmpty(richTextJson);
  }

  /// Feature 3.5: 状態遷移。連打ガードで進行中は無視。
  Future<void> _requestStow(StickyNote note, StowState next) async {
    if (note.stowState == next) {
      return;
    }
    final transitions = ref.read(noteTransitionStartProvider.notifier);
    if (!transitions.beginTransition(note.id)) {
      // 既に遷移中: 無視。
      return;
    }

    try {
      // Notifier 側の state 更新 (persistence 書き込みは 500ms debounce)。
      await ref
          .read(noteWindowNotifierProvider.notifier)
          .updateStowState(next);

      // サブウィンドウ自体のサイズを変える。
      final size = windowSizeForState(next, note.width, note.height);
      final controller = widget.windowController;
      if (controller != null) {
        try {
          await controller.setFrame(
            Rect.fromLTWH(
              note.positionX,
              note.positionY,
              size.width,
              size.height,
            ),
          );
        } catch (error) {
          // setFrame の失敗は UX を壊さないよう無視してログのみ。
          debugPrint('NoteWindowShell.setFrame failed: $error');
        }
      }

      // メインへ通知 (Feature 3.5 の UI 同期)。
      await widget.onStowStateChanged?.call(next);

      // アニメ + リサイズ完了をおおまかに待って解放。
      await Future<void>.delayed(kNoteWindowTransitionDuration);
    } finally {
      // beginTransition から一定時間後には自動解除されるが、明示解除で確実に。
      transitions.endTransition(note.id);
    }
  }

  /// Feature 3.2: 「閉じる」は通常 isPanelOpen=false + window close。
  ///
  /// Phase 2c 修正 2: SwiftUI の hideToGroup() と同じく、空ノート (text が空白のみ &&
  /// richText も実質空) は Inbox を汚染しないよう**削除**する。非空は従来通り。
  ///
  /// メインの NoteManager state を合わせるため、window.close 前に IPC で
  /// 空なら `noteWindow.deleteNote`、非空なら `noteWindow.panelClosed` を送信する。
  Future<void> _requestClose(StickyNote note) async {
    final isEmpty = isNoteEmptyForCloseDeletion(
      text: note.text,
      richText: note.richText,
    );

    if (isEmpty) {
      // 削除経路: IPC でメインに deleteNote を依頼 → ウィンドウを閉じる。
      try {
        await widget.onDeleteConfirmed?.call();
      } catch (error) {
        debugPrint('NoteWindowShell.onDeleteConfirmed (empty close) failed: $error');
      }
    } else {
      // 従来の閉じる経路: state を isPanelOpen=false に更新してメインへ通知。
      await ref.read(noteWindowNotifierProvider.notifier).markPanelClosed();
      try {
        await widget.onPanelClosed?.call();
      } catch (error) {
        debugPrint('NoteWindowShell.onPanelClosed failed: $error');
      }
    }

    final controller = widget.windowController;
    if (controller != null) {
      try {
        await controller.close();
      } catch (error) {
        debugPrint('NoteWindowShell.close failed: $error');
      }
    }
  }
}
