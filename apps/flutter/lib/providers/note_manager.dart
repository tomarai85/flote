// NoteManager (Sprint 2 Feature 2.3 本実装)。
//
// Riverpod 2.x の AsyncNotifier ベースで、PersistenceService と接続する。
// - 起動時に loadNotes() で state を初期化 (AsyncValue)。
// - 全 mutation は 500ms debounce の save (Timer + _pendingSave フラグ)。
// - App 終了時は flushSaveNow() で pending を即座に flush。
//
// 現行 SwiftUI 版 NoteManager.swift の挙動移植:
// - createNote はグループ自動割当しない (空メモが Inbox を汚染しない)。
// - moveNote(toGroup:) で sortedAt を更新 (Groups タブのソート用)。
// - bringToFront で zOrder を最大 + 1。
//
// Sprint 1 の StateNotifierProvider から AsyncNotifierProvider へ移行済み。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_color_theme.dart';
import '../models/sticky_note.dart';
import '../models/stow_state.dart';
import '../services/persistence_service.dart';

/// PersistenceService Provider。テストで override しやすいように分離する。
final persistenceServiceProvider = Provider<PersistenceService>((ref) {
  return PersistenceService();
});

/// NoteManager Provider。
///
/// AsyncNotifierProvider を使うことで、起動時の `loadNotes()` 完了を UI 側が
/// `AsyncValue.when` でハンドルできるようになる。
final noteManagerProvider =
    AsyncNotifierProvider<NoteManager, List<StickyNote>>(NoteManager.new);

/// NoteManager: ノートの CRUD と状態更新、500ms debounce 保存を担当する。
class NoteManager extends AsyncNotifier<List<StickyNote>> {
  /// 500ms debounce の保存タイマ。build() の外で操作するため late ではなく nullable。
  Timer? _saveDebounce;

  /// save が走っている最中に追加 mutation が起きた場合、もう一度 save するかを示すフラグ。
  /// 単純化のため、Sprint 2 では debounce タイマ再セットで済ませる (flag は廃止)。

  /// 書き込みサービス。build() で注入する。
  late final PersistenceService _persistence;

  /// createNote で既定値として使う新規ノートの幅・高さ。
  ///
  /// 現行 SwiftUI 版は 160 固定。Sprint 3 でリサイズ可能にする。
  static const double _defaultWidth = 160;
  static const double _defaultHeight = 120;

  /// debounce 時間 (ms)。
  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  @override
  Future<List<StickyNote>> build() async {
    _persistence = ref.read(persistenceServiceProvider);

    // dispose 時に pending timer をキャンセル。
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveDebounce = null;
    });

    final notes = await _persistence.loadNotes();
    return notes;
  }

  /// 現在の state を同期的に取得する。まだ build 完了前なら空リストを返す。
  List<StickyNote> get _current {
    return state.value ?? const [];
  }

  /// state を新しいリストで差し替え、debounce save をスケジュールする。
  void _updateNotes(List<StickyNote> next) {
    state = AsyncData(next);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_saveDebounceDuration, () async {
      await _persistNow();
    });
  }

  Future<void> _persistNow() async {
    // build が未完了なら何もしない (通常は起きないが念のため)。
    final snapshot = state.value;
    if (snapshot == null) {
      return;
    }
    try {
      await _persistence.saveNotes(snapshot);
    } catch (error, stackTrace) {
      // 書き込み失敗は state には反映しない (UI 側に error 通知する場合は
      // 別 Provider で扱う方針)。ログのみ残す。
      stderr.writeln('NoteManager.saveNotes failed: $error\n$stackTrace');
    }
  }

  /// App 終了時に pending save を即座に flush する。
  Future<void> flushSaveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persistNow();
  }

  /// Single-writer pattern (M0 audit fix 2026-05-10):
  /// サブウィンドウから IPC で受信した note 全体を main 側 state に partial
  /// update する。Sub engine は file IO を行わなくなったので、main がここで
  /// state 更新 + debounce save をまとめて担当 = persistence の writer は
  /// main engine のみ = 並行編集 lost-update race を解消。
  ///
  /// 該当 id が無ければ append (新規作成中の race を許容)。
  Future<void> applySubWindowUpdate(StickyNote updated) async {
    final current = _current;
    final next = <StickyNote>[];
    var replaced = false;
    for (final n in current) {
      if (n.id == updated.id) {
        next.add(updated);
        replaced = true;
      } else {
        next.add(n);
      }
    }
    if (!replaced) {
      next.add(updated);
    }
    _updateNotes(next);
  }

  /// ノートを新規作成する。グループへは自動割当しない (現行挙動踏襲)。
  ///
  /// [positionX] / [positionY] が指定されると、その座標で作成する。省略時は (0, 0)。
  /// 画面中央 + ジッターでの配置は呼び出し側 (UI 層) で計算し、引数で渡す。
  /// 理由: スクリーンサイズ取得は platform 依存 (window_manager) であり、
  ///       provider 層を platform フリーに保つため。
  ///
  /// 返り値は作成したノート (呼び出し側でウィンドウを開く等に使う)。
  Future<StickyNote> createNote({
    String initialText = '',
    NoteColorTheme? colorTheme,
    double positionX = 0,
    double positionY = 0,
  }) async {
    final current = _current;
    final now = DateTime.now();
    final id = _generateId();
    final nextZ = current.isEmpty
        ? 1
        : (current.map((n) => n.zOrder).reduce(max) + 1);

    final note = StickyNote(
      id: id,
      text: initialText,
      richText: '',
      positionX: positionX,
      positionY: positionY,
      width: _defaultWidth,
      height: _defaultHeight,
      colorTheme: colorTheme ?? _pickDefaultColor(current),
      createdAt: now,
      modifiedAt: now,
      zOrder: nextZ,
      stowState: StowState.expanded,
      rolledTitle: '',
      groupID: null,
      isPanelOpen: true,
      sortedAt: null,
      shapes: const [],
    );

    _updateNotes([...current, note]);
    return note;
  }

  /// ID でノート削除。存在しない場合は no-op。
  Future<void> deleteNote(String id) async {
    final current = _current;
    final next = current.where((n) => n.id != id).toList(growable: false);
    if (next.length == current.length) {
      return;
    }
    _updateNotes(next);
  }

  /// 削除されたノートをハンドルとして取得する。history 送信前の情報取得に使う。
  /// 存在しない場合は null。
  StickyNote? noteById(String id) {
    for (final n in _current) {
      if (n.id == id) {
        return n;
      }
    }
    return null;
  }

  /// Sprint 5 Feature 5.5: 履歴から復元されたノートを state に追加する。
  /// 呼び出し元 (HistoryManager) が新規 ID と groupID = Inbox を設定済みである想定。
  Future<void> insertRestoredNote(StickyNote restored) async {
    final current = _current;
    // ID 衝突防止: 既に同じ ID があれば追加しない (異常系)。
    if (current.any((n) => n.id == restored.id)) {
      return;
    }
    _updateNotes([...current, restored]);
  }

  /// Sprint 5 Feature 5.2: AI Sort で既存グループへ割当 or 新規グループ作成後の
  /// 割り当てを一括適用するためのバルク更新。
  /// mapping: noteId -> groupID (null は Inbox 意味ではなく未分類扱いなので、
  /// 呼び出し元は必要に応じて NoteGroup.inboxId を渡す)。
  Future<void> assignNotesToGroups(Map<String, String?> mapping) async {
    if (mapping.isEmpty) {
      return;
    }
    final current = _current;
    final now = DateTime.now();
    var changed = false;
    final next = <StickyNote>[];
    for (final note in current) {
      if (mapping.containsKey(note.id)) {
        final newGroup = mapping[note.id];
        if (note.groupID != newGroup) {
          next.add(note.copyWith(groupID: newGroup, sortedAt: now));
          changed = true;
          continue;
        }
      }
      next.add(note);
    }
    if (!changed) {
      return;
    }
    _updateNotes(next);
  }

  /// プレーンテキストを更新する。modifiedAt を現時刻に更新。
  Future<void> updateText(String id, String text) async {
    await _mutate(id, (note) {
      return note.copyWith(text: text, modifiedAt: DateTime.now());
    });
  }

  /// rich text (flutter_quill Delta JSON) を更新する。Sprint 4 で本接続。
  Future<void> updateRichText(String id, String richText) async {
    await _mutate(id, (note) {
      return note.copyWith(richText: richText, modifiedAt: DateTime.now());
    });
  }

  Future<void> updatePosition(String id, double x, double y) async {
    await _mutate(id, (note) {
      return note.copyWith(positionX: x, positionY: y);
    });
  }

  Future<void> updateSize(String id, double width, double height) async {
    await _mutate(id, (note) {
      return note.copyWith(width: width, height: height);
    });
  }

  Future<void> updateColorTheme(String id, NoteColorTheme colorTheme) async {
    await _mutate(id, (note) {
      return note.copyWith(
        colorTheme: colorTheme,
        modifiedAt: DateTime.now(),
      );
    });
  }

  Future<void> updateStowState(String id, StowState stowState) async {
    await _mutate(id, (note) {
      return note.copyWith(stowState: stowState);
    });
  }

  /// ウィンドウクリック時等で最前面化する。
  Future<void> bringToFront(String id) async {
    final current = _current;
    if (current.isEmpty) {
      return;
    }
    final maxZ = current.map((n) => n.zOrder).reduce(max);
    await _mutate(id, (note) {
      if (note.zOrder == maxZ) {
        return note;
      }
      return note.copyWith(zOrder: maxZ + 1);
    });
  }

  /// ノートのパネル開閉を切り替える (現行の "閉じる" ボタン用、Sprint 3 で本接続)。
  Future<void> setPanelOpen(String id, bool isOpen) async {
    await _mutate(id, (note) {
      return note.copyWith(isPanelOpen: isOpen);
    });
  }

  /// ノートをグループに移動し、sortedAt を更新する。
  /// groupID に null を渡すと未分類に戻す。
  Future<void> moveNote(String id, String? groupID) async {
    await _mutate(id, (note) {
      return note.copyWith(
        groupID: groupID,
        sortedAt: DateTime.now(),
      );
    });
  }

  /// 指定グループに属するノート一覧を返す。null を渡すと未分類ノートを返す。
  List<StickyNote> notesInGroup(String? groupID) {
    return _current.where((note) => note.groupID == groupID).toList();
  }

  /// 内部: id のノートを transformer で更新し、state と save を更新する。
  Future<void> _mutate(
    String id,
    StickyNote Function(StickyNote) transform,
  ) async {
    final current = _current;
    var changed = false;
    final next = <StickyNote>[];
    for (final note in current) {
      if (note.id == id) {
        final updated = transform(note);
        if (!identical(updated, note)) {
          changed = true;
        }
        next.add(updated);
      } else {
        next.add(note);
      }
    }
    if (!changed) {
      return;
    }
    _updateNotes(next);
  }

  /// 現行 SwiftUI 版の色被り回避ロジック (Sprint 4 Feature 4.2 本実装)。
  /// 現在開いているノートと色が被らない色を選ぶ。全色使用済みならランダム。
  ///
  /// 実体は `pickAvailableNoteColor` (models/note_color_theme.dart) に集約。
  NoteColorTheme _pickDefaultColor(List<StickyNote> current) {
    final rng = Random();
    return pickAvailableNoteColor(
      current.where((n) => n.isPanelOpen).map((n) => n.colorTheme),
      randomInt: rng.nextInt,
    );
  }

  /// ID 生成。UUID ライブラリ未使用なのでランダム文字列で代用する (衝突確率は実用上ゼロ)。
  String _generateId() {
    final rng = Random();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final rand = rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'note-$now-$rand';
  }
}
