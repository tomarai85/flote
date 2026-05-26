// GroupManager (Sprint 2 Feature 2.4 本実装)。
//
// - 起動時に loadGroups() で state を初期化、Inbox がなければ自動作成。
// - createGroup / deleteGroup / renameGroup / children / ループ検出 128 深まで。
// - deleteGroup は子グループを root に昇格、子ノートを Inbox に移動する (現行踏襲)。
// - ループ検出: createGroup と reparent で 128 深を超えたら親を null に戻す。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/note_group.dart';
import '../services/persistence_service.dart';
import 'note_manager.dart';

/// 親子階層の最大深度 (spec より)。
const int kMaxGroupDepth = 128;

/// GroupManager Provider。
final groupManagerProvider =
    AsyncNotifierProvider<GroupManager, List<NoteGroup>>(GroupManager.new);

class GroupManager extends AsyncNotifier<List<NoteGroup>> {
  Timer? _saveDebounce;
  late final PersistenceService _persistence;

  static const Duration _saveDebounceDuration = Duration(milliseconds: 500);

  @override
  Future<List<NoteGroup>> build() async {
    _persistence = ref.read(persistenceServiceProvider);
    ref.onDispose(() {
      _saveDebounce?.cancel();
      _saveDebounce = null;
    });

    final stored = await _persistence.loadGroups();
    final withInbox = _ensureInbox(stored);
    if (!_listIdentical(stored, withInbox)) {
      // Inbox を今追加した場合、保存しておく。build() 内なので await する。
      await _persistence.saveGroups(withInbox);
    }
    return withInbox;
  }

  List<NoteGroup> get _current => state.value ?? const [];

  void _updateGroups(List<NoteGroup> next) {
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
    final snapshot = state.value;
    if (snapshot == null) {
      return;
    }
    try {
      await _persistence.saveGroups(snapshot);
    } catch (error, stackTrace) {
      stderr.writeln('GroupManager.saveGroups failed: $error\n$stackTrace');
    }
  }

  Future<void> flushSaveNow() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _persistNow();
  }

  /// Inbox が無ければ先頭に追加したリストを返す (元の順序は維持)。
  List<NoteGroup> _ensureInbox(List<NoteGroup> groups) {
    final hasInbox = groups.any((g) => g.id == NoteGroup.inboxId);
    if (hasInbox) {
      return groups;
    }
    final inbox = NoteGroup(
      id: NoteGroup.inboxId,
      name: 'Inbox',
      parentGroupID: null,
      iconName: 'tray',
      colorHex: null,
      createdAt: DateTime.now(),
    );
    return [inbox, ...groups];
  }

  bool _listIdentical(List<NoteGroup> a, List<NoteGroup> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) {
        return false;
      }
    }
    return true;
  }

  /// 既に state 上に存在する Inbox を保証する (テスト等の明示呼び出し用)。
  Future<void> ensureInboxExists() async {
    final current = _current;
    final withInbox = _ensureInbox(current);
    if (!_listIdentical(current, withInbox)) {
      _updateGroups(withInbox);
    }
  }

  /// グループを新規作成する。親にループが発生する場合は parentGroupID を null にフォールバック。
  Future<NoteGroup> createGroup({
    required String name,
    String? parentGroupID,
    String? iconName,
    String? colorHex,
  }) async {
    final current = _current;
    final safeParent = _parentOrNullIfLoop(current, null, parentGroupID);
    final id = _generateId();
    final group = NoteGroup(
      id: id,
      name: name,
      parentGroupID: safeParent,
      iconName: iconName,
      colorHex: colorHex,
      createdAt: DateTime.now(),
    );
    _updateGroups([...current, group]);
    return group;
  }

  /// グループをリネームする。
  Future<void> renameGroup(String id, String newName) async {
    final current = _current;
    final index = current.indexWhere((g) => g.id == id);
    if (index < 0) {
      return;
    }
    final next = [...current];
    next[index] = current[index].copyWith(name: newName);
    _updateGroups(next);
  }

  /// 親グループを変更する。ループが発生する場合は null にフォールバック。
  Future<void> reparent(String id, String? newParentId) async {
    final current = _current;
    final index = current.indexWhere((g) => g.id == id);
    if (index < 0) {
      return;
    }
    final safeParent = _parentOrNullIfLoop(current, id, newParentId);
    final next = [...current];
    next[index] = current[index].copyWith(parentGroupID: safeParent);
    _updateGroups(next);
  }

  /// グループを削除する。子グループを root に昇格、子ノートを Inbox に移動。
  /// Inbox は削除不可 (no-op)。
  Future<void> deleteGroup(String id) async {
    if (id == NoteGroup.inboxId) {
      return;
    }
    final current = _current;
    final exists = current.any((g) => g.id == id);
    if (!exists) {
      return;
    }

    // 子グループを root 昇格。
    final updatedGroups = current
        .where((g) => g.id != id)
        .map((g) {
          if (g.parentGroupID == id) {
            return g.copyWith(parentGroupID: null);
          }
          return g;
        })
        .toList(growable: false);

    _updateGroups(updatedGroups);

    // 子ノートを Inbox へ移動 (NoteManager 経由)。
    // NoteManager が未構築の場合は ref.read が build を待つため注意 (flushSaveNow 相当)。
    final notes = await ref.read(noteManagerProvider.future);
    for (final note in notes) {
      if (note.groupID == id) {
        await ref.read(noteManagerProvider.notifier).moveNote(
              note.id,
              NoteGroup.inboxId,
            );
      }
    }
  }

  /// 子グループ一覧を返す (深さ 1、再帰的な孫は別メソッドで)。
  List<NoteGroup> children(String parentId) {
    return _current.where((g) => g.parentGroupID == parentId).toList();
  }

  /// 指定グループの祖先を root まで辿ったリストを返す (自分を含まない)。
  /// 128 深でエスケープする。
  List<NoteGroup> ancestors(String id) {
    final current = _current;
    final byId = <String, NoteGroup>{
      for (final g in current) g.id: g,
    };
    final result = <NoteGroup>[];
    var pointer = byId[id]?.parentGroupID;
    var depth = 0;
    while (pointer != null && depth < kMaxGroupDepth) {
      final parent = byId[pointer];
      if (parent == null) {
        break;
      }
      result.add(parent);
      pointer = parent.parentGroupID;
      depth++;
    }
    return result;
  }

  /// 指定親候補 `candidateParent` を `childId` の親に設定すると
  /// ループまたは 128 深超過が起きるかを判定する。
  /// 起こるなら null を返す、起きないなら candidateParent をそのまま返す。
  /// `childId` は新規作成時は null でよい (親だけ候補を評価)。
  String? _parentOrNullIfLoop(
    List<NoteGroup> groups,
    String? childId,
    String? candidateParent,
  ) {
    if (candidateParent == null) {
      return null;
    }
    if (childId != null && candidateParent == childId) {
      return null;
    }
    final byId = <String, NoteGroup>{
      for (final g in groups) g.id: g,
    };
    final parent = byId[candidateParent];
    if (parent == null) {
      // 親が存在しない → ループでは無いが、整合性確保のため null に戻す。
      return null;
    }
    // candidateParent の祖先を辿って childId が現れるか確認。
    var pointer = parent.parentGroupID;
    var depth = 1;
    while (pointer != null && depth < kMaxGroupDepth) {
      if (childId != null && pointer == childId) {
        return null;
      }
      final next = byId[pointer];
      if (next == null) {
        break;
      }
      pointer = next.parentGroupID;
      depth++;
    }
    if (depth >= kMaxGroupDepth) {
      return null;
    }
    return candidateParent;
  }

  String _generateId() {
    final rng = Random();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final rand = rng.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return 'group-$now-$rand';
  }
}

