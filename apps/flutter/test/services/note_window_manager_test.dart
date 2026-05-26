// Sprint 3 Feature 3.1 / 3.3 / 3.4 ウィンドウサイズロジックとマネージャの
// 基本挙動 (adapter モック使用) のテスト。
//
// 実プラットフォーム呼び出しは NoteWindowManager の MultiWindowAdapter を
// 偽物に差し替えて検証する。

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';
import 'package:flote_desktop/services/note_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void _initBinding() {
  // MethodChannel を使うため ServicesBinding を初期化。
  TestWidgetsFlutterBinding.ensureInitialized();
}

class _FakeAdapter extends MultiWindowAdapter {
  _FakeAdapter() : super();

  int _nextId = 1;
  final List<String> createdPayloads = [];
  final List<int> showCalls = [];
  final List<int> closeCalls = [];
  final Map<int, String> titles = {};
  final Map<int, List<double>> lastFrames = {};

  @override
  Future<int?> createWindow(String argumentsAsJson) async {
    createdPayloads.add(argumentsAsJson);
    return _nextId++;
  }

  @override
  Future<void> setTitle(int windowId, String title) async {
    titles[windowId] = title;
  }

  @override
  Future<void> setFrame(
    int windowId, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) async {
    lastFrames[windowId] = [left, top, width, height];
  }

  @override
  Future<void> show(int windowId) async {
    showCalls.add(windowId);
  }

  @override
  Future<void> close(int windowId) async {
    closeCalls.add(windowId);
  }
}

StickyNote _makeNote({
  String id = 'note-1',
  StowState stow = StowState.expanded,
  double width = 160,
  double height = 120,
  double x = 50,
  double y = 60,
}) {
  final now = DateTime.now();
  return StickyNote(
    id: id,
    text: 'hello',
    richText: '',
    positionX: x,
    positionY: y,
    width: width,
    height: height,
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
  _initBinding();

  group('windowSizeForState', () {
    test('expanded は引数の width/height をそのまま返す', () {
      final s = windowSizeForState(StowState.expanded, 200, 150);
      expect(s.width, 200);
      expect(s.height, 150);
    });

    test('rolledUp は 26px 固定高さ (幅は expanded と同じ)', () {
      final s = windowSizeForState(StowState.rolledUp, 200, 150);
      expect(s.width, 200);
      expect(s.height, 26);
    });

    test('mini は 36x36 固定 (Phase 2: SwiftUI MiniNoteView 準拠)', () {
      final s = windowSizeForState(StowState.mini, 200, 150);
      expect(s.width, 36);
      expect(s.height, 36);
    });
  });

  group('NoteWindowManager', () {
    test('openWindowForNote: 新規作成とマップ登録', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);

      final note = _makeNote();
      final id = await manager.openWindowForNote(note);
      expect(id, isNotNull);
      expect(manager.openWindowCount, 1);
      expect(manager.isOpen('note-1'), isTrue);
      expect(fake.createdPayloads.length, 1);
      expect(fake.showCalls, contains(id));
      expect(fake.titles[id!], 'Flote Note note-1');
    });

    test('同じ noteId で 2 回呼んでも 1 ウィンドウのみ', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);
      final note = _makeNote();

      await manager.openWindowForNote(note);
      await manager.openWindowForNote(note);
      expect(manager.openWindowCount, 1);
      expect(fake.createdPayloads.length, 1);
      // 2 回目は show 再呼び出し。
      expect(fake.showCalls.length, 2);
    });

    test('closeWindowForNote でウィンドウ数が減る', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);
      final note = _makeNote();

      await manager.openWindowForNote(note);
      await manager.closeWindowForNote('note-1');
      expect(manager.openWindowCount, 0);
      expect(manager.isOpen('note-1'), isFalse);
      expect(fake.closeCalls.length, 1);
    });

    test('resizeForState: 状態に応じたサイズを setFrame で適用', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);
      final note = _makeNote();

      final id = await manager.openWindowForNote(note);
      // mini 状態のノートに差し替えて resize を呼ぶ。
      final miniNote = _makeNote(stow: StowState.mini);
      await manager.resizeForState('note-1', miniNote);
      final frame = fake.lastFrames[id]!;
      // Phase 2: SwiftUI 準拠で mini は 36x36
      expect(frame[2], 36); // width
      expect(frame[3], 36); // height
    });

    test('noteIdForWindow で逆引きできる', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);
      final note = _makeNote();

      final id = await manager.openWindowForNote(note);
      expect(manager.noteIdForWindow(id!), 'note-1');
      expect(manager.noteIdForWindow(99999), isNull);
    });

    test('closeAll で全ウィンドウが閉じる', () async {
      final fake = _FakeAdapter();
      final manager = NoteWindowManager(adapter: fake);

      await manager.openWindowForNote(_makeNote(id: 'n1'));
      await manager.openWindowForNote(_makeNote(id: 'n2'));
      expect(manager.openWindowCount, 2);

      await manager.closeAll();
      expect(manager.openWindowCount, 0);
      expect(fake.closeCalls.length, 2);
    });
  });
}
