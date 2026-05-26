// Sprint 5: HistoryManager のテスト。

import 'dart:io';

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/note_group.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';
import 'package:flote_desktop/providers/history_manager.dart';
import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Directory> _makeTempDir() async {
  return Directory.systemTemp.createTemp('flote_history_test_');
}

StickyNote _makeNote({required String id, String text = 'hello'}) {
  return StickyNote(
    id: id,
    text: text,
    richText: '',
    positionX: 0,
    positionY: 0,
    width: 160,
    height: 120,
    colorTheme: NoteColorTheme.yellow,
    createdAt: DateTime.now(),
    modifiedAt: DateTime.now(),
    zOrder: 1,
    stowState: StowState.expanded,
    rolledTitle: '',
    groupID: null,
    isPanelOpen: true,
    sortedAt: null,
    shapes: const [],
  );
}

ProviderContainer _makeContainer(PersistenceService persistence) {
  return ProviderContainer(
    overrides: [
      persistenceServiceProvider.overrideWithValue(persistence),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HistoryManager', () {
    test('addFromDeletedNote: 追加されると Provider state に現れる', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);

      final note = _makeNote(id: 'n-1', text: '消しました');
      await container
          .read(historyManagerProvider.notifier)
          .addFromDeletedNote(note);

      final entries =
          await container.read(historyManagerProvider.future);
      expect(entries.length, 1);
      expect(entries.first.id, 'n-1');
      expect(entries.first.text, '消しました');
    });

    test('上限 100 件で古いものが削除される', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);
      final notifier = container.read(historyManagerProvider.notifier);

      for (var i = 0; i < 105; i++) {
        await notifier.addFromDeletedNote(_makeNote(id: 'n-$i', text: 't-$i'));
      }

      final entries =
          await container.read(historyManagerProvider.future);
      expect(entries.length, kHistoryMaxEntries);
      // 最新 (n-104) が先頭、古い (n-5) が末尾 (pruning で n-0 ~ n-4 が落ちる)
      expect(entries.first.id, 'n-104');
      expect(entries.last.id, 'n-5');
    });

    test('permanentlyDelete: エントリが消える', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);
      final notifier = container.read(historyManagerProvider.notifier);

      await notifier.addFromDeletedNote(_makeNote(id: 'a'));
      await notifier.addFromDeletedNote(_makeNote(id: 'b'));
      await notifier.permanentlyDelete('a');

      final entries = await container.read(historyManagerProvider.future);
      expect(entries.map((e) => e.id), ['b']);
    });

    test('clearAll: 全エントリが消える', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);
      final notifier = container.read(historyManagerProvider.notifier);

      await notifier.addFromDeletedNote(_makeNote(id: 'a'));
      await notifier.addFromDeletedNote(_makeNote(id: 'b'));
      await notifier.clearAll();

      final entries = await container.read(historyManagerProvider.future);
      expect(entries, isEmpty);
    });

    test('restoreToInbox: NoteManager に復元ノートが追加され、groupID は Inbox', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(noteManagerProvider.future);
      await container.read(historyManagerProvider.future);
      final historyNotifier =
          container.read(historyManagerProvider.notifier);

      await historyNotifier.addFromDeletedNote(
        _makeNote(id: 'original-1', text: '復元してね'),
      );

      final entries =
          await container.read(historyManagerProvider.future);
      final ok = await historyNotifier.restoreToInbox(entries.first.id);
      expect(ok, isTrue);

      final notes = await container.read(noteManagerProvider.future);
      expect(notes.length, 1);
      expect(notes.first.text, '復元してね');
      expect(notes.first.groupID, NoteGroup.inboxId);
      expect(notes.first.id, isNot('original-1')); // 新規 ID

      final remaining =
          await container.read(historyManagerProvider.future);
      expect(remaining, isEmpty);
    });

    test('flushSaveNow で history.json が書き出される', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);
      final notifier = container.read(historyManagerProvider.notifier);
      await notifier.addFromDeletedNote(_makeNote(id: 'a', text: 'saveme'));
      await notifier.flushSaveNow();

      final reloaded = await persistence.loadHistory();
      expect(reloaded.length, 1);
      expect(reloaded.first.text, 'saveme');
    });

    test('存在しない id の restoreToInbox は false', () async {
      final dir = await _makeTempDir();
      final persistence = PersistenceService(baseOverride: dir);
      final container = _makeContainer(persistence);
      addTearDown(container.dispose);

      await container.read(historyManagerProvider.future);
      final ok = await container
          .read(historyManagerProvider.notifier)
          .restoreToInbox('nope');
      expect(ok, isFalse);
    });
  });
}
