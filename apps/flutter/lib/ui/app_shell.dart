// Sprint 2 Feature 2.5: プレースホルダ ListView UI。
//
// メインウィンドウ中央にノート一覧を表示し、新規/削除ボタンを配置する。
// Sprint 3 で独立ウィンドウ (desktop_multi_window) に置換される捨てコード前提。
//
// デザインは MVP レベル (tokens を使って雑多なハードコードを避けるのみ)。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Phase 2c: screen_retriever は window_manager の transitive dependency 経由で利用可能。
// ignore: depend_on_referenced_packages
import 'package:screen_retriever/screen_retriever.dart';

import '../models/note_color_theme.dart';
import '../models/sticky_note.dart';
import '../providers/note_manager.dart';
import '../services/note_position_calculator.dart';
import '../theme/tokens.dart';

/// ノートを独立ウィンドウで開く時に使うコールバック型。
typedef OpenNoteCallback = Future<void> Function(StickyNote note);

class AppShell extends ConsumerWidget {
  const AppShell({super.key, this.onOpenNote});

  /// ノート行の「開く」ボタン、または「新規」ボタンから呼ばれる。
  /// main.dart の _HomeShell から NoteWindowManager を橋渡しする。
  /// null の場合はウィンドウ操作をスキップ (テスト用途)。
  final OpenNoteCallback? onOpenNote;

  /// Primary display の visible frame を取得する (フォールバック付き)。
  /// Phase 2c: 新規ノート位置計算で使用。
  Future<Rect> _primaryVisibleFrame() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final size = display.visibleSize ?? display.size;
      final origin = display.visiblePosition ?? Offset.zero;
      return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
    } catch (_) {
      return defaultVisibleFrame();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(noteManagerProvider);

    return Scaffold(
      backgroundColor: ColorTokens.surface,
      appBar: AppBar(
        backgroundColor: ColorTokens.surface,
        elevation: 0,
        title: Text(
          'Flote',
          style: TypographyTokens.heading.copyWith(
            color: ColorTokens.onSurface,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: SpacingTokens.md),
            child: FilledButton.icon(
              onPressed: () async {
                // Phase 2c 修正 1: 画面中央 + ジッター配置で新規ノートを作成。
                final visibleFrame = await _primaryVisibleFrame();
                final offset = calculateNewNotePosition(
                  visibleFrame: visibleFrame,
                );
                final note = await ref
                    .read(noteManagerProvider.notifier)
                    .createNote(
                      positionX: offset.dx,
                      positionY: offset.dy,
                    );
                if (onOpenNote != null) {
                  await onOpenNote!(note);
                }
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新規'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: notesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.all(SpacingTokens.lg),
              child: Text(
                'ノートの読み込みに失敗しました: $error',
                style: TypographyTokens.body.copyWith(color: ColorTokens.error),
              ),
            ),
          ),
          data: (notes) => _NotesPane(notes: notes, onOpenNote: onOpenNote),
        ),
      ),
    );
  }
}

class _NotesPane extends ConsumerWidget {
  const _NotesPane({required this.notes, this.onOpenNote});

  final List<StickyNote> notes;
  final OpenNoteCallback? onOpenNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (notes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingTokens.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'ノートがまだありません',
                style: TypographyTokens.body.copyWith(
                  color: ColorTokens.onSurfaceMuted,
                ),
              ),
              const SizedBox(height: SpacingTokens.sm),
              Text(
                '右上の「新規」ボタンで作成できます',
                style: TypographyTokens.caption.copyWith(
                  color: ColorTokens.onSurfaceMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(SpacingTokens.md),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const SizedBox(height: SpacingTokens.sm),
      itemBuilder: (context, index) {
        final note = notes[index];
        return _NoteRow(note: note, onOpenNote: onOpenNote);
      },
    );
  }
}

class _NoteRow extends ConsumerStatefulWidget {
  const _NoteRow({required this.note, this.onOpenNote});

  final StickyNote note;
  final OpenNoteCallback? onOpenNote;

  @override
  ConsumerState<_NoteRow> createState() => _NoteRowState();
}

class _NoteRowState extends ConsumerState<_NoteRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note.text);
  }

  @override
  void didUpdateWidget(covariant _NoteRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部から text が変わった場合は controller も同期する (カーソル位置は簡易的にリセット)。
    if (widget.note.text != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.note.text,
        selection: TextSelection.collapsed(offset: widget.note.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    final background = note.colorTheme.background;
    final text = note.colorTheme.textColor;
    final manager = ref.read(noteManagerProvider.notifier);

    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(RadiusTokens.medium),
        border: Border.all(color: ColorTokens.onSurfaceMuted.withValues(alpha: 0.15)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SpacingTokens.md,
        vertical: SpacingTokens.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 3,
              style: TypographyTokens.body.copyWith(color: text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'メモを入力',
                hintStyle: TypographyTokens.body.copyWith(
                  color: text.withValues(alpha: 0.45),
                ),
              ),
              onChanged: (value) {
                manager.updateText(note.id, value);
              },
            ),
          ),
          const SizedBox(width: SpacingTokens.sm),
          if (widget.onOpenNote != null)
            IconButton(
              tooltip: 'ウィンドウで開く',
              icon: Icon(Icons.open_in_new, color: text, size: 18),
              onPressed: () async {
                // 先にパネル開状態に更新してからウィンドウを開く。
                await manager.setPanelOpen(note.id, true);
                await widget.onOpenNote!(note);
              },
            ),
          IconButton(
            tooltip: '削除',
            icon: Icon(Icons.delete_outline, color: text, size: 18),
            onPressed: () async {
              await manager.deleteNote(note.id);
            },
          ),
        ],
      ),
    );
  }
}
