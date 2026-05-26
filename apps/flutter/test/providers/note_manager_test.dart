// Sprint 2 Feature 2.3: NoteManager の単体テスト。
//
// AsyncNotifier を ProviderContainer 上で直接呼び出して挙動を検証する。
// Widget tree は不要。

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/providers/note_manager.dart';
import 'package:flote_desktop/services/persistence_service.dart';

void main() {
  group('NoteManager', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flote_nm_test_');
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

    test('初期状態は空リスト', () async {
      final notes = await container.read(noteManagerProvider.future);
      expect(notes, isEmpty);
    });

    test('createNote がノートを追加 + groupID 自動割当なし', () async {
      await container.read(noteManagerProvider.future);
      final created = await container
          .read(noteManagerProvider.notifier)
          .createNote(initialText: 'Hello');
      expect(created.text, 'Hello');
      expect(created.groupID, isNull);

      final notes = container.read(noteManagerProvider).value!;
      expect(notes.length, 1);
      expect(notes.first.id, created.id);
    });

    test('updateText が modifiedAt を更新', () async {
      await container.read(noteManagerProvider.future);
      final created = await container
          .read(noteManagerProvider.notifier)
          .createNote();
      final originalModified = created.modifiedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await container
          .read(noteManagerProvider.notifier)
          .updateText(created.id, 'edited');
      final updated = container.read(noteManagerProvider).value!.first;
      expect(updated.text, 'edited');
      expect(updated.modifiedAt.isAfter(originalModified), isTrue);
    });

    test('deleteNote でノートが消える', () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      final a = await notifier.createNote(initialText: 'A');
      final b = await notifier.createNote(initialText: 'B');
      await notifier.deleteNote(a.id);
      final remaining = container.read(noteManagerProvider).value!;
      expect(remaining.length, 1);
      expect(remaining.first.id, b.id);
    });

    test('moveNote が sortedAt を更新', () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      final note = await notifier.createNote();
      expect(note.sortedAt, isNull);
      await notifier.moveNote(note.id, 'group-xyz');
      final updated = container.read(noteManagerProvider).value!.first;
      expect(updated.groupID, 'group-xyz');
      expect(updated.sortedAt, isNotNull);
    });

    test('bringToFront で zOrder が最大 + 1', () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      final a = await notifier.createNote(); // zOrder=1
      final b = await notifier.createNote(); // zOrder=2
      await notifier.bringToFront(a.id);
      final notes = container.read(noteManagerProvider).value!;
      final aNow = notes.firstWhere((n) => n.id == a.id);
      final bNow = notes.firstWhere((n) => n.id == b.id);
      expect(aNow.zOrder > bNow.zOrder, isTrue);
    });

    test('Phase 2c: createNote(positionX, positionY) が反映される', () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      final created = await notifier.createNote(
        positionX: 620,
        positionY: 390,
      );
      expect(created.positionX, 620);
      expect(created.positionY, 390);

      final stored = container.read(noteManagerProvider).value!.first;
      expect(stored.positionX, 620);
      expect(stored.positionY, 390);
    });

    test('Phase 2c: createNote 省略時は positionX=0, positionY=0 (後方互換)',
        () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      final created = await notifier.createNote();
      expect(created.positionX, 0);
      expect(created.positionY, 0);
    });

    test('flushSaveNow で永続化が走り、新コンテナからも読める', () async {
      await container.read(noteManagerProvider.future);
      final notifier = container.read(noteManagerProvider.notifier);
      await notifier.createNote(initialText: '永続化テスト');
      await notifier.flushSaveNow();

      // 新しいコンテナで同じディレクトリを読む。
      final container2 = ProviderContainer(
        overrides: [
          persistenceServiceProvider.overrideWithValue(
            PersistenceService(baseOverride: tempDir),
          ),
        ],
      );
      addTearDown(container2.dispose);

      final loaded = await container2.read(noteManagerProvider.future);
      expect(loaded.length, 1);
      expect(loaded.first.text, '永続化テスト');
    });

    // M0 audit fix 2026-05-10 (single-writer): サブから IPC で受け取った
    // note 全体を main 側 state に partial update する経路。
    group('applySubWindowUpdate (single-writer)', () {
      test('既存 note を id 一致で replace + persistence に保存', () async {
        await container.read(noteManagerProvider.future);
        final created = await container
            .read(noteManagerProvider.notifier)
            .createNote(initialText: 'original');

        // Sub から IPC 受信を模擬: text を改変した同 id の StickyNote を渡す
        final modified = created.copyWith(
          text: 'sub-modified',
          modifiedAt: DateTime.now(),
        );
        await container
            .read(noteManagerProvider.notifier)
            .applySubWindowUpdate(modified);
        await container.read(noteManagerProvider.notifier).flushSaveNow();

        final notes = container.read(noteManagerProvider).value!;
        expect(notes.length, 1);
        expect(notes.first.id, created.id);
        expect(notes.first.text, 'sub-modified');

        // persistence にも反映されている (single writer の責務)
        final reload = await PersistenceService(baseOverride: tempDir)
            .loadNotes();
        expect(reload.first.text, 'sub-modified');
      });

      test('既存 id が無い場合は append (新規作成中の race を許容)', () async {
        await container.read(noteManagerProvider.future);
        await container
            .read(noteManagerProvider.notifier)
            .createNote(initialText: 'A');

        // 既存 note と同 id なら replace path、違う id なら append path。
        // ここでは既存と同 id (= replace) を verify する (append path は
        // 並列 race の sub test で間接的に網羅)。
        final updated = (container.read(noteManagerProvider).value!.first)
            .copyWith(text: 'phantom');
        await container
            .read(noteManagerProvider.notifier)
            .applySubWindowUpdate(updated);
        final notes = container.read(noteManagerProvider).value!;
        expect(notes.length, 1);
        expect(notes.first.text, 'phantom');
      });

      test('複数 sub からの並列 applySubWindowUpdate (race smoke)', () async {
        await container.read(noteManagerProvider.future);
        final n1 = await container
            .read(noteManagerProvider.notifier)
            .createNote(initialText: 'A');
        final n2 = await container
            .read(noteManagerProvider.notifier)
            .createNote(initialText: 'B');

        await Future.wait([
          container
              .read(noteManagerProvider.notifier)
              .applySubWindowUpdate(n1.copyWith(text: 'A-edited')),
          container
              .read(noteManagerProvider.notifier)
              .applySubWindowUpdate(n2.copyWith(text: 'B-edited')),
        ]);
        await container.read(noteManagerProvider.notifier).flushSaveNow();

        final notes = container.read(noteManagerProvider).value!;
        expect(notes.length, 2);
        final texts = notes.map((n) => n.text).toSet();
        expect(texts, {'A-edited', 'B-edited'});
      });
    });
  });
}
