// サブウィンドウ (1 ノート 1 ウィンドウ) 内部の state モデル。
//
// 重要: サブウィンドウは main isolate とは別 Flutter engine で動作するため、
// メインの NoteManager (Riverpod) とは state を共有できない。
//
// Single-writer pattern (M0 audit fix 2026-05-10):
//  1. 起動時に noteId を引数で受け取り、PersistenceService から全ノートを読み込む
//  2. 該当ノートの情報を元に UI を描画
//  3. 変更は **persistence に書き戻さない** (load-modify-write race の元凶だった)。
//     代わりに DesktopMultiWindow IPC で main にノート全体を payload として送信。
//  4. main 側 (`noteManagerProvider.applySubWindowUpdate`) が state を更新 +
//     debounce save する (single writer = main engine のみ)。

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/note_color_theme.dart';
import '../../models/sticky_note.dart';
import '../../models/stow_state.dart';
import '../../services/persistence_service.dart';

/// サブウィンドウ起動時に親から渡される引数。main 側の
/// NoteWindowManager.openWindowForNote と同期する。
class NoteWindowArguments {
  const NoteWindowArguments({
    required this.noteId,
    this.initialText,
    this.stowState,
  });

  /// 対象ノートの id。必須。
  final String noteId;

  /// 任意: 起動時の参考情報 (persistence から読み直すため厳密一致は求めない)。
  final String? initialText;
  final StowState? stowState;

  factory NoteWindowArguments.fromJson(Map<String, dynamic> json) {
    return NoteWindowArguments(
      noteId: json['noteId'] as String? ?? '',
      initialText: json['initialText'] as String?,
      stowState: json['stowState'] is String
          ? parseStowState(json['stowState'] as String)
          : null,
    );
  }
}

/// サブウィンドウの state。
class NoteWindowState {
  const NoteWindowState({required this.note, this.isSaving = false});

  final StickyNote note;
  final bool isSaving;

  NoteWindowState copyWith({StickyNote? note, bool? isSaving}) {
    return NoteWindowState(
      note: note ?? this.note,
      isSaving: isSaving ?? this.isSaving,
    );
  }
}

/// サブウィンドウ用の persistence provider (main と別コンテナで生きる)。
final noteWindowPersistenceProvider = Provider<PersistenceService>((ref) {
  return PersistenceService();
});

/// サブウィンドウ起動引数を provider 化。main.dart の sub-window entry で
/// ProviderScope(overrides: [...]) で上書きする。
final noteWindowArgumentsProvider = Provider<NoteWindowArguments>((ref) {
  throw UnimplementedError(
    'noteWindowArgumentsProvider は ProviderScope.overrides で初期値を与える必要があります',
  );
});

/// サブ -> メイン IPC 送信コールバック (J-2 + Single-writer M0 fix 2026-05-10)。
///
/// `NoteWindowNotifier._persistNow` (現在は file IO せず通知のみ) から呼ばれ、
/// 更新後の StickyNote 全体を payload として main へ送る。main 側は
/// `noteManagerProvider.applySubWindowUpdate(note)` で state 更新 + debounce save。
/// テスト環境では no-op に override できるよう Provider 化している。
typedef NoteWindowUpdatedNotifier = Future<void> Function(StickyNote note);

final noteWindowUpdatedNotifierProvider = Provider<NoteWindowUpdatedNotifier>(
  (ref) => _defaultNoteUpdatedNotifier,
);

Future<void> _defaultNoteUpdatedNotifier(StickyNote note) async {
  // デフォルト (test 環境等) では no-op。
  // 本体 entry 側で override して DesktopMultiWindow.invokeMethod を呼ぶ。
}

/// サブウィンドウの NotifierProvider。
final noteWindowNotifierProvider =
    AsyncNotifierProvider<NoteWindowNotifier, NoteWindowState>(
      NoteWindowNotifier.new,
    );

class NoteWindowNotifier extends AsyncNotifier<NoteWindowState> {
  Timer? _saveDebounce;
  late final PersistenceService _persistence;
  late final String _noteId;

  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  @override
  Future<NoteWindowState> build() async {
    _persistence = ref.read(noteWindowPersistenceProvider);
    final args = ref.read(noteWindowArgumentsProvider);
    _noteId = args.noteId;

    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveDebounce = null;
    });

    final all = await _persistence.loadNotes();
    final target = all.firstWhere(
      (n) => n.id == _noteId,
      orElse: () => _fallbackNote(_noteId, args),
    );
    return NoteWindowState(note: target);
  }

  /// プレーンテキスト更新。
  Future<void> updateText(String text) async {
    await _mutate((note) {
      return note.copyWith(text: text, modifiedAt: DateTime.now());
    });
  }

  /// Sprint 4 Feature 4.1: rich text (flutter_quill Delta JSON 文字列) を更新。
  /// plainText を同時に渡すと text フィールドも同期更新する (rolledTitle 自動生成用)。
  Future<void> updateRichText(String richTextJson, {String? plainText}) async {
    await _mutate((note) {
      if (plainText != null) {
        return note.copyWith(
          richText: richTextJson,
          text: plainText,
          modifiedAt: DateTime.now(),
        );
      }
      return note.copyWith(
        richText: richTextJson,
        modifiedAt: DateTime.now(),
      );
    });
  }

  /// ウィンドウ位置更新 (ドラッグ移動後に呼ぶ)。
  Future<void> updatePosition(double x, double y) async {
    await _mutate((note) {
      return note.copyWith(positionX: x, positionY: y);
    });
  }

  /// ウィンドウサイズ更新 (expanded のリサイズ、または状態遷移時)。
  Future<void> updateSize(double width, double height) async {
    await _mutate((note) {
      return note.copyWith(width: width, height: height);
    });
  }

  /// 状態遷移 (expanded / rolledUp / mini)。
  Future<void> updateStowState(StowState next) async {
    await _mutate((note) {
      // rolledUp のタイトルが空なら text 先頭 12 文字に。
      if (next == StowState.rolledUp &&
          note.rolledTitle.isEmpty &&
          note.text.isNotEmpty) {
        final trimmed = note.text.length > 12
            ? note.text.substring(0, 12)
            : note.text;
        return note.copyWith(stowState: next, rolledTitle: trimmed);
      }
      return note.copyWith(stowState: next);
    });
  }

  /// カラーテーマ更新。
  Future<void> updateColorTheme(NoteColorTheme theme) async {
    await _mutate((note) {
      return note.copyWith(colorTheme: theme, modifiedAt: DateTime.now());
    });
  }

  /// 「閉じる != 削除」: isPanelOpen = false にして save する。
  /// 呼び出し側でウィンドウを close する。
  Future<void> markPanelClosed() async {
    await _mutate((note) {
      return note.copyWith(isPanelOpen: false);
    });
    await flushSaveNow();
  }

  /// pending save を即 flush。
  Future<void> flushSaveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persistNow();
  }

  Future<void> _mutate(StickyNote Function(StickyNote) transform) async {
    final snap = state.value;
    if (snap == null) {
      return;
    }
    final updated = transform(snap.note);
    if (identical(updated, snap.note)) {
      return;
    }
    state = AsyncData(snap.copyWith(note: updated));
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_saveDebounceDuration, () async {
      await _persistNow();
    });
  }

  /// Single-writer pattern (M0 audit fix 2026-05-10):
  /// Sub engine は file を **書かない**。代わりに最新の StickyNote 全体を
  /// IPC で main engine に送信し、main 側 NoteManager が state 更新 + debounce
  /// save する。これにより複数 sub engine 並行編集時の lost-update race を解消。
  Future<void> _persistNow() async {
    final snap = state.value;
    if (snap == null) {
      return;
    }
    try {
      final notify = ref.read(noteWindowUpdatedNotifierProvider);
      await notify(snap.note);
    } catch (error, stackTrace) {
      stderr.writeln(
        'NoteWindowNotifier notify noteUpdated failed: $error\n$stackTrace',
      );
    }
  }

  /// persistence に該当ノートが見つからない場合のフォールバック。
  /// 起動時引数を元に最低限の StickyNote を組み立てる。
  StickyNote _fallbackNote(String id, NoteWindowArguments args) {
    final now = DateTime.now();
    return StickyNote(
      id: id,
      text: args.initialText ?? '',
      richText: '',
      positionX: 80,
      positionY: 80,
      width: 160,
      height: 120,
      colorTheme: NoteColorTheme.yellow,
      createdAt: now,
      modifiedAt: now,
      zOrder: 1,
      stowState: args.stowState ?? StowState.expanded,
      rolledTitle: '',
      groupID: null,
      isPanelOpen: true,
      sortedAt: null,
      shapes: const [],
    );
  }
}
