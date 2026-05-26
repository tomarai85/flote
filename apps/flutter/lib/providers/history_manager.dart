// HistoryManager (Sprint 5 Feature 5.5)。
//
// 削除済みノートの履歴を保持する。
// - add: deleteNote 時に呼び、history.json に書き出す (100 件上限、古いものから pruning)
// - remove(id): 永久削除 (復元せずリストから除外)
// - clear: 全履歴削除
// - restore(id): 履歴からノートを Inbox に復元 (NoteManager へ橋渡し)
//
// 注意:
// - history.json は notes.json と独立。atomic write + bak。
// - 最大 100 件。append 時に超過なら deletedAt の古い順で pruning。
// - 復元時は新規 ID を振り、groupID は必ず Inbox (spec の M9 踏襲)。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_entry.dart';
import '../models/note_group.dart';
import '../models/sticky_note.dart';
import '../models/stow_state.dart';
import 'note_manager.dart';

/// 履歴最大件数。これを超えたら古いものから削除する。
const int kHistoryMaxEntries = 100;

final historyManagerProvider =
    AsyncNotifierProvider<HistoryManager, List<HistoryEntry>>(
  HistoryManager.new,
);

class HistoryManager extends AsyncNotifier<List<HistoryEntry>> {
  Timer? _saveDebounce;
  static const Duration _debounce = Duration(milliseconds: 500);

  @override
  Future<List<HistoryEntry>> build() async {
    final persistence = ref.read(persistenceServiceProvider);
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveDebounce = null;
    });
    try {
      final loaded = await persistence.loadHistory();
      // 新しい順に並べる (deletedAt 降順)。
      final sorted = [...loaded]
        ..sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
      return sorted;
    } catch (error) {
      stderr.writeln('HistoryManager.loadHistory failed: $error');
      return const [];
    }
  }

  List<HistoryEntry> get _current => state.value ?? const [];

  void _updateEntries(List<HistoryEntry> next) {
    state = AsyncData(next);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(_debounce, () async {
      await _persistNow();
    });
  }

  Future<void> _persistNow() async {
    final snapshot = state.value;
    if (snapshot == null) {
      return;
    }
    try {
      await ref.read(persistenceServiceProvider).saveHistory(snapshot);
    } catch (error, stackTrace) {
      stderr.writeln('HistoryManager.saveHistory failed: $error\n$stackTrace');
    }
  }

  Future<void> flushSaveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persistNow();
  }

  /// 削除されたノートを履歴に追加する。NoteManager.deleteNote 直前に呼ぶ想定。
  Future<void> addFromDeletedNote(StickyNote note) async {
    final entry = HistoryEntry(
      id: note.id,
      deletedAt: DateTime.now(),
      text: note.text,
      richText: note.richText,
      colorTheme: note.colorTheme,
      originalGroupID: note.groupID,
    );

    // 新しいものが先頭、古いものが末尾。上限超過なら末尾 (最古) を切る。
    final next = [entry, ..._current];
    if (next.length > kHistoryMaxEntries) {
      next.removeRange(kHistoryMaxEntries, next.length);
    }
    _updateEntries(next);
  }

  /// 履歴を永久削除する (復元せずエントリだけ除外)。
  Future<void> permanentlyDelete(String id) async {
    final next = _current.where((e) => e.id != id).toList(growable: false);
    if (next.length == _current.length) {
      return;
    }
    _updateEntries(next);
  }

  /// 全履歴を削除する。
  Future<void> clearAll() async {
    if (_current.isEmpty) {
      return;
    }
    _updateEntries(const []);
  }

  /// 履歴から新規ノートとして Inbox に復元する。
  ///
  /// - 復元後の `StickyNote` は新規 ID + groupID = Inbox に強制割当 (M9)。
  /// - NoteManager を経由して state に追加する。
  /// - 履歴からは該当エントリを削除。
  /// 失敗時は false を返す。成功時 true。
  Future<bool> restoreToInbox(String id) async {
    final index = _current.indexWhere((e) => e.id == id);
    if (index < 0) {
      return false;
    }
    final entry = _current[index];

    // NoteManager へ復元ノートを追加する。
    try {
      final noteManager = ref.read(noteManagerProvider.notifier);
      await ref.read(noteManagerProvider.future);

      final restored = _buildRestoredNote(entry);
      await noteManager.insertRestoredNote(restored);
    } catch (error, stackTrace) {
      stderr.writeln('HistoryManager.restoreToInbox failed: $error\n$stackTrace');
      return false;
    }

    // 履歴からエントリを取り除く。
    final next = _current.where((e) => e.id != id).toList(growable: false);
    _updateEntries(next);
    return true;
  }

  /// 新規 ID + Inbox 割当で復元 StickyNote を組み立てる。
  StickyNote _buildRestoredNote(HistoryEntry entry) {
    final rng = Random();
    final now = DateTime.now();
    final microHex = now.microsecondsSinceEpoch.toRadixString(16);
    final randHex = rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final newId = 'note-$microHex-$randHex';
    return StickyNote(
      id: newId,
      text: entry.text,
      richText: entry.richText,
      positionX: 120,
      positionY: 120,
      width: 160,
      height: 120,
      colorTheme: entry.colorTheme,
      createdAt: now,
      modifiedAt: now,
      zOrder: 1,
      stowState: StowState.expanded,
      rolledTitle: '',
      groupID: NoteGroup.inboxId,
      isPanelOpen: false,
      sortedAt: now,
      shapes: const [],
    );
  }
}

// NoteColorTheme を直接 import する設計に変更したので、sentinel クラスは不要。
// restoreToInbox は indexWhere で直接存在判定する。
