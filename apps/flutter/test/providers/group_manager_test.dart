// Sprint 2 Feature 2.4: GroupManager の単体テスト。
//
// - 初回起動で Inbox が自動作成される
// - createGroup / deleteGroup / 親子ループ検出 / children
// - deleteGroup で子ノートが Inbox に移動

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/note_group.dart';
import 'package:flote_desktop/providers/group_manager.dart';
import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';

void main() {
  group('GroupManager', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flote_gm_test_');
      container = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(
            PersistenceService(baseOverride: tempDir),
          ),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('初回起動で Inbox が自動作成', () async {
      final groups = await container.read(groupManagerProvider.future);
      expect(groups.any((g) => g.id == NoteGroup.inboxId), isTrue);
      final inbox = groups.firstWhere((g) => g.id == NoteGroup.inboxId);
      expect(inbox.name, 'Inbox');
      expect(inbox.parentGroupID, isNull);
    });

    test('createGroup で全属性を明示設定', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final group = await notifier.createGroup(
        name: 'プロジェクト',
        iconName: 'folder',
        colorHex: '#FF9900',
      );
      expect(group.name, 'プロジェクト');
      expect(group.iconName, 'folder');
      expect(group.colorHex, '#FF9900');
      expect(group.parentGroupID, isNull);
    });

    test('children(parent) が子グループ一覧を返す', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final parent = await notifier.createGroup(name: 'parent');
      await notifier.createGroup(name: 'child-1', parentGroupID: parent.id);
      await notifier.createGroup(name: 'child-2', parentGroupID: parent.id);
      final children = notifier.children(parent.id);
      expect(children.length, 2);
      final names = children.map((g) => g.name).toSet();
      expect(names, {'child-1', 'child-2'});
    });

    test('親子ループ検出: 孫を自分の親に設定するとループ回避で null', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final a = await notifier.createGroup(name: 'A');
      final b = await notifier.createGroup(name: 'B', parentGroupID: a.id);
      final c = await notifier.createGroup(name: 'C', parentGroupID: b.id);

      // A の親を C にしようとするとループ (A -> C -> B -> A) になる。
      await notifier.reparent(a.id, c.id);
      final groups = container.read(groupManagerProvider).value!;
      final aNow = groups.firstWhere((g) => g.id == a.id);
      expect(aNow.parentGroupID, isNull);
    });

    test('自分を自分の親にしようとすると null', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final a = await notifier.createGroup(name: 'A');
      await notifier.reparent(a.id, a.id);
      final groups = container.read(groupManagerProvider).value!;
      expect(groups.firstWhere((g) => g.id == a.id).parentGroupID, isNull);
    });

    test('deleteGroup で子グループは root に昇格', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final parent = await notifier.createGroup(name: 'parent');
      final child = await notifier.createGroup(
        name: 'child',
        parentGroupID: parent.id,
      );
      await notifier.deleteGroup(parent.id);
      final groups = container.read(groupManagerProvider).value!;
      expect(groups.any((g) => g.id == parent.id), isFalse);
      final childNow = groups.firstWhere((g) => g.id == child.id);
      expect(childNow.parentGroupID, isNull);
    });

    test('deleteGroup で子ノートが Inbox に移動', () async {
      await container.read(groupManagerProvider.future);
      final groupNotifier = container.read(groupManagerProvider.notifier);
      final noteNotifier = container.read(noteManagerProvider.notifier);
      await container.read(noteManagerProvider.future);

      final g = await groupNotifier.createGroup(name: 'temp');
      final note = await noteNotifier.createNote(initialText: 'hello');
      await noteNotifier.moveNote(note.id, g.id);

      await groupNotifier.deleteGroup(g.id);

      final notes = container.read(noteManagerProvider).value!;
      final moved = notes.firstWhere((n) => n.id == note.id);
      expect(moved.groupID, NoteGroup.inboxId);
    });

    test('Inbox は削除不可 (no-op)', () async {
      await container.read(groupManagerProvider.future);
      final notifier = container.read(groupManagerProvider.notifier);
      final before = container.read(groupManagerProvider).value!;
      await notifier.deleteGroup(NoteGroup.inboxId);
      final after = container.read(groupManagerProvider).value!;
      expect(after.length, before.length);
      expect(after.any((g) => g.id == NoteGroup.inboxId), isTrue);
    });
  });
}
