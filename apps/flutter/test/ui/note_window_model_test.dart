// Sprint 3 Feature 3.2 / 3.5 サブウィンドウ用 NoteWindowNotifier のテスト。
//
// PersistenceService を一時ディレクトリで差し替え、updateText / updateStowState /
// markPanelClosed / flushSaveNow の挙動を検証する。

import 'dart:io';

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flote_desktop/ui/note_window/note_window_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

StickyNote _note(String id, {String text = 'hello', StowState stow = StowState.expanded}) {
  final now = DateTime(2026, 1, 1);
  return StickyNote(
    id: id,
    text: text,
    richText: '',
    positionX: 10,
    positionY: 20,
    width: 160,
    height: 120,
    colorTheme: NoteColorTheme.yellow,
    createdAt: now,
    modifiedAt: now,
    zOrder: 1,
    stowState: stow,
    rolledTitle: '',
    groupID: null,
    isPanelOpen: true,
    sortedAt: null,
    shapes: const [],
  );
}

void main() {
  late Directory tmpDir;
  late PersistenceService persistence;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('note_window_model_');
    persistence = PersistenceService(baseOverride: tmpDir);
  });

  tearDown(() async {
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // M0 audit fix 2026-05-10 (single-writer): Sub engine は file を書かない。
  // 代わりに invocations capture で「IPC で送られた最新 StickyNote」を verify する。
  late List<StickyNote> invocations;

  ProviderContainer buildContainer(NoteWindowArguments args) {
    invocations = <StickyNote>[];
    return ProviderContainer(
      overrides: [
        noteWindowPersistenceProvider.overrideWithValue(persistence),
        noteWindowArgumentsProvider.overrideWithValue(args),
        noteWindowUpdatedNotifierProvider.overrideWithValue(
          (note) async => invocations.add(note),
        ),
      ],
    );
  }

  test('起動時 persistence から該当ノートを読み込む', () async {
    await persistence.saveNotes([_note('n1', text: 'seed')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final state = await container.read(noteWindowNotifierProvider.future);
    expect(state.note.id, 'n1');
    expect(state.note.text, 'seed');
  });

  test('該当 id が無い場合はフォールバック StickyNote を生成', () async {
    await persistence.saveNotes([_note('other')]);

    final container = buildContainer(
      const NoteWindowArguments(
        noteId: 'missing',
        initialText: 'fallback text',
        stowState: StowState.rolledUp,
      ),
    );
    addTearDown(container.dispose);

    final state = await container.read(noteWindowNotifierProvider.future);
    expect(state.note.id, 'missing');
    expect(state.note.text, 'fallback text');
    expect(state.note.stowState, StowState.rolledUp);
  });

  test('updateText が state を変えて flushSaveNow で persistence に反映', () async {
    await persistence.saveNotes([_note('n1')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateText('updated!');
    await notifier.flushSaveNow();

    expect(invocations, isNotEmpty);
    expect(invocations.last.text, 'updated!');
  });

  test('updateStowState=rolledUp で rolledTitle を自動設定', () async {
    await persistence.saveNotes([_note('n1', text: '0123456789ABCDEFGHIJ')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateStowState(StowState.rolledUp);
    await notifier.flushSaveNow();

    expect(invocations.last.stowState, StowState.rolledUp);
    expect(invocations.last.rolledTitle, '0123456789AB'); // 先頭 12 文字
  });

  test('markPanelClosed で isPanelOpen=false の payload が IPC 送出される', () async {
    await persistence.saveNotes([_note('n1')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.markPanelClosed();

    expect(invocations.last.isPanelOpen, isFalse);
  });

  test('対象ノートだけ payload に乗せ、他ノート (n1) には触れない', () async {
    await persistence.saveNotes([
      _note('n1', text: 'first'),
      _note('n2', text: 'second'),
    ]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n2'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateText('second-updated');
    await notifier.flushSaveNow();

    // Sub は自分の note (n2) のみを payload として IPC 送出する。
    // n1 のことは知らない (single-writer; main 側でマージ責務)。
    expect(invocations.length, 1);
    expect(invocations.first.id, 'n2');
    expect(invocations.first.text, 'second-updated');
    // 他ノート (n1) は file に initial state のまま残る (sub が触らない)。
    final saved = await persistence.loadNotes();
    final byId = {for (final n in saved) n.id: n};
    expect(byId['n1']!.text, 'first');
    expect(byId['n2']!.text, 'second'); // sub は file を書かないので initial
  });

  // J-1: updatePosition が state と persistence に反映されること。
  test('updatePosition で state.note.position が更新され persist される', () async {
    await persistence.saveNotes([_note('n1')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updatePosition(210.5, 340.75);
    await notifier.flushSaveNow();

    expect(invocations.last.positionX, 210.5);
    expect(invocations.last.positionY, 340.75);

    // 「再起動相当」 test は新仕様 (single-writer) では sub からの persist が
    // 無いので、再読込しても位置は復元されない (main 経由で persist される
    // フローは note_manager_test.applySubWindowUpdate でカバー)。
    final container2 = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container2.dispose);
    final reloaded = await container2.read(noteWindowNotifierProvider.future);
    expect(reloaded.note.positionX, 10); // initial _note() の値
    expect(reloaded.note.positionY, 20);
  });

  // J-1: updateSize が state と persistence に反映されること。
  test('updateSize で state.note.size が更新され persist される', () async {
    await persistence.saveNotes([_note('n1')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateSize(200, 300);
    await notifier.flushSaveNow();

    expect(invocations.last.width, 200);
    expect(invocations.last.height, 300);
  });

  // Sprint 4 Feature 4.1: updateRichText が Delta JSON と plainText を同時保存。
  test('updateRichText が richText と text を同時更新する', () async {
    await persistence.saveNotes([_note('n1', text: 'old')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    const deltaJson = '[{"insert":"hello world\\n"}]';
    await notifier.updateRichText(deltaJson, plainText: 'hello world');
    await notifier.flushSaveNow();

    expect(invocations.last.richText, deltaJson);
    expect(invocations.last.text, 'hello world');
  });

  test('updateRichText は plainText 未指定でも richText だけ更新する', () async {
    await persistence.saveNotes([_note('n1', text: 'keep')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateRichText('[{"insert":"x\\n"}]');
    await notifier.flushSaveNow();

    expect(invocations.last.richText, '[{"insert":"x\\n"}]');
    expect(invocations.last.text, 'keep'); // text は据え置き
  });

  // Sprint 4 Feature 4.2: updateColorTheme でカラーテーマが切替わる。
  test('updateColorTheme で colorTheme が保存される', () async {
    await persistence.saveNotes([_note('n1')]);

    final container = buildContainer(
      const NoteWindowArguments(noteId: 'n1'),
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateColorTheme(NoteColorTheme.blue);
    await notifier.flushSaveNow();

    expect(invocations.last.colorTheme, NoteColorTheme.blue);
  });

  // M0 audit fix 2026-05-10 (single-writer):
  // _persistNow は file を書かず、StickyNote 全体を payload として
  // noteWindowUpdatedNotifierProvider 経由で main に送信する。
  test('flushSaveNow で noteUpdated notifier に最新 StickyNote が渡る', () async {
    await persistence.saveNotes([_note('n1')]);

    final invocations = <StickyNote>[];
    final container = ProviderContainer(
      overrides: [
        noteWindowPersistenceProvider.overrideWithValue(persistence),
        noteWindowArgumentsProvider.overrideWithValue(
          const NoteWindowArguments(noteId: 'n1'),
        ),
        noteWindowUpdatedNotifierProvider.overrideWithValue(
          (note) async => invocations.add(note),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateText('poke');
    await notifier.flushSaveNow();

    expect(invocations.length, 1);
    expect(invocations.first.id, 'n1');
    expect(invocations.first.text, 'poke');
  });

  // M0 audit fix verify: Sub engine は persistence に書き戻さない。
  // (旧仕様だと load-modify-write race の元凶だった)
  test('flushSaveNow しても persistence file は更新されない (single-writer)', () async {
    final initial = _note('n1');
    await persistence.saveNotes([initial]);

    final container = ProviderContainer(
      overrides: [
        noteWindowPersistenceProvider.overrideWithValue(persistence),
        noteWindowArgumentsProvider.overrideWithValue(
          const NoteWindowArguments(noteId: 'n1'),
        ),
        // notifier は no-op default のまま
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(noteWindowNotifierProvider.notifier);
    await container.read(noteWindowNotifierProvider.future);

    await notifier.updateText('sub-modified');
    await notifier.flushSaveNow();

    final saved = await persistence.loadNotes();
    // 期待: persistence の text は initial のまま (sub は書かない)。
    // main が IPC 経由で書く責務を持つ。
    expect(saved.first.text, initial.text);
  });
}
