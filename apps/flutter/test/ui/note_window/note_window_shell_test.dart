// Sprint 3-5 / Mode 0 audit B-1, A-5, A-1: NoteWindowShell の widget test。
//
// 2026-05-10 wholesale rewrite:
//  - 旧 file は Generator subagent が private `_requestStow` 直叩きを仮定して書いた
//    ため、実 widget tree (GestureDetector tap → onStowStateChange callback →
//    shell._requestStow) と不整合で 11/14 fail。@Skip で全 skip 状態だった。
//  - 本書き直しでは「実 widget tap simulation」を徹底し、callback chain を
//    実際のユーザー操作と同じ経路で発火させる。
//
// 9 シナリオ:
//  1. AsyncNotifier loading state -> CircularProgressIndicator (Completer 経由)
//  2. stowState=mini -> NoteMiniView 表示
//  3. stowState=rolledUp -> NoteRolledUpView 表示
//  4. mini view tap -> onStowStateChanged(expanded)
//  5. mini view 連打ガード (transition lock during in-flight)
//  6. controller.setFrame throw でも UI crash せず state 反映
//  7. onStowStateChanged callback throw でも finally で endTransition (B-1)
//  8. 空ノート + archive -> onDeleteConfirmed + window.close
//  9. 非空ノート + archive -> markPanelClosed + onPanelClosed + window.close
//
// 重要: pumpAndSettle は QuillEditor の continuous animation で hang する
// (旧 audit Wave 4 で確認済) ため使わず、`pump() + pump(Duration)` で進める。
// PersistenceService は SynchronousFuture で全 IO を即値解決する
// `_SyncPersistenceService` に置換し、AsyncNotifier.build() を即解決させる。

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flote_desktop/models/app_settings.dart';
import 'package:flote_desktop/models/history_entry.dart';
import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/note_group.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';
import 'package:flote_desktop/providers/note_manager.dart' show persistenceServiceProvider;
import 'package:flote_desktop/providers/note_window_transition.dart';
import 'package:flote_desktop/services/persistence_service.dart';
import 'package:flote_desktop/ui/note_window/note_window_model.dart';
import 'package:flote_desktop/ui/note_window/note_window_shell.dart';
import 'package:flote_desktop/ui/note_window/states/expanded_view.dart';
import 'package:flote_desktop/ui/note_window/states/mini_view.dart';
import 'package:flote_desktop/ui/note_window/states/rolled_up_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// PersistenceService を全 IO method 即値解決 (SynchronousFuture) で override。
/// AsyncNotifier.build() の `await loadNotes()` を loading state を経由せず
/// 即 data state にする = test での CircularProgressIndicator hang を回避。
class _SyncPersistenceService extends PersistenceService {
  _SyncPersistenceService({List<StickyNote> notes = const []})
      : _notes = List<StickyNote>.from(notes);

  List<StickyNote> _notes;

  @override
  Future<List<StickyNote>> loadNotes() {
    return SynchronousFuture<List<StickyNote>>(List.unmodifiable(_notes));
  }

  @override
  Future<void> saveNotes(List<StickyNote> notes) {
    _notes = List<StickyNote>.from(notes);
    return SynchronousFuture<void>(null);
  }

  @override
  Future<List<NoteGroup>> loadGroups() => SynchronousFuture(const []);

  @override
  Future<void> saveGroups(List<NoteGroup> groups) => SynchronousFuture(null);

  @override
  Future<List<HistoryEntry>> loadHistory() => SynchronousFuture(const []);

  @override
  Future<void> saveHistory(List<HistoryEntry> entries) =>
      SynchronousFuture(null);

  @override
  Future<AppSettings> loadSettings() =>
      SynchronousFuture(AppSettings.defaults());

  @override
  Future<void> saveSettings(AppSettings settings) =>
      SynchronousFuture(null);
}

/// loading state テスト専用: loadNotes() を Completer で人為的に保留する。
/// `complete([...])` を呼ぶまで AsyncNotifier.build() が解決せず、
/// shell は CircularProgressIndicator を描画する。
class _CompleterPersistenceService extends PersistenceService {
  final Completer<List<StickyNote>> notesCompleter =
      Completer<List<StickyNote>>();

  @override
  Future<List<StickyNote>> loadNotes() => notesCompleter.future;

  @override
  Future<void> saveNotes(List<StickyNote> notes) => SynchronousFuture(null);

  @override
  Future<List<NoteGroup>> loadGroups() => SynchronousFuture(const []);

  @override
  Future<void> saveGroups(List<NoteGroup> groups) => SynchronousFuture(null);

  @override
  Future<List<HistoryEntry>> loadHistory() => SynchronousFuture(const []);

  @override
  Future<void> saveHistory(List<HistoryEntry> entries) =>
      SynchronousFuture(null);

  @override
  Future<AppSettings> loadSettings() =>
      SynchronousFuture(AppSettings.defaults());

  @override
  Future<void> saveSettings(AppSettings settings) => SynchronousFuture(null);
}

// 既存パラメータ (closeThrows / windowIdValue) は将来のテスト追加に備えて残す。
// ignore_for_file: unused_element_parameter

class _FakeWindowController extends WindowController {
  _FakeWindowController({
    this.setFrameThrows = false,
    this.closeThrows = false,
    this.windowIdValue = 1,
  });

  bool setFrameThrows;
  bool closeThrows;
  final int windowIdValue;

  final List<Rect> setFrameCalls = <Rect>[];
  int closeCount = 0;

  @override
  int get windowId => windowIdValue;

  @override
  Future<void> close() async {
    closeCount++;
    if (closeThrows) {
      throw StateError('fake close failed');
    }
  }

  @override
  Future<void> setFrame(Rect frame) async {
    setFrameCalls.add(frame);
    if (setFrameThrows) {
      throw StateError('fake setFrame failed');
    }
  }

  @override
  Future<void> show() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> center() async {}

  @override
  Future<void> setTitle(String title) async {}

  @override
  Future<void> resizable(bool resizable) async {}

  @override
  Future<void> setFrameAutosaveName(String name) async {}
}

StickyNote _seedNote({
  String id = 'n-shell-1',
  String text = '',
  String richText = '',
  StowState stow = StowState.mini,
  NoteColorTheme color = NoteColorTheme.yellow,
}) {
  final now = DateTime(2026, 5, 10);
  return StickyNote(
    id: id,
    text: text,
    richText: richText,
    positionX: 100,
    positionY: 200,
    width: 160,
    height: 120,
    colorTheme: color,
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

Widget _harness({
  required ProviderContainer container,
  required _FakeWindowController? controller,
  Future<void> Function(StowState)? onStowStateChanged,
  Future<void> Function()? onPanelClosed,
  Future<void> Function()? onDeleteConfirmed,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: NoteWindowShell(
        windowController: controller,
        onStowStateChanged: onStowStateChanged,
        onPanelClosed: onPanelClosed,
        onDeleteConfirmed: onDeleteConfirmed,
      ),
    ),
  );
}

ProviderContainer _buildContainer({
  required PersistenceService persistence,
  required NoteWindowArguments args,
}) {
  return ProviderContainer(
    overrides: [
      // サブウィンドウ用 (NoteWindowNotifier が読む)
      noteWindowPersistenceProvider.overrideWithValue(persistence),
      // メイン用 (appSettingsProvider 等が読む)
      persistenceServiceProvider.overrideWithValue(persistence),
      noteWindowArgumentsProvider.overrideWithValue(args),
      // notify は no-op
      noteWindowUpdatedNotifierProvider.overrideWithValue((_) async {}),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ======== シナリオ 1: AsyncNotifier loading state (A-5 race guard) ========
  testWidgets('1. build 解決前は CircularProgressIndicator を描画', (tester) async {
    final persistence = _CompleterPersistenceService();
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(
      container: container,
      controller: _FakeWindowController(),
    ));
    // Completer 未解決 -> AsyncNotifier は loading state
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 子 view は描画されていない
    expect(find.byType(NoteMiniView), findsNothing);
    expect(find.byType(NoteRolledUpView), findsNothing);
    expect(find.byType(NoteExpandedView), findsNothing);

    // 解決 -> data state
    persistence.notesCompleter.complete(
      List<StickyNote>.unmodifiable([_seedNote(stow: StowState.mini)]),
    );
    await tester.pump(); // microtask flush
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(NoteMiniView), findsOneWidget);
  });

  // ======== シナリオ 2: stowState=mini -> NoteMiniView 表示 ========
  testWidgets('2. stowState=mini -> NoteMiniView を描画', (tester) async {
    final persistence =
        _SyncPersistenceService(notes: [_seedNote(stow: StowState.mini)]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(
      container: container,
      controller: _FakeWindowController(),
    ));
    await tester.pump();

    expect(find.byType(NoteMiniView), findsOneWidget);
    expect(find.byType(NoteRolledUpView), findsNothing);
    expect(find.byType(NoteExpandedView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  // ======== シナリオ 3: stowState=rolledUp -> NoteRolledUpView 表示 ========
  testWidgets('3. stowState=rolledUp -> NoteRolledUpView を描画', (tester) async {
    final persistence = _SyncPersistenceService(
      notes: [_seedNote(stow: StowState.rolledUp, text: 'hi')],
    );
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_harness(
      container: container,
      controller: _FakeWindowController(),
    ));
    await tester.pump();

    expect(find.byType(NoteRolledUpView), findsOneWidget);
    expect(find.byType(NoteMiniView), findsNothing);
    expect(find.byType(NoteExpandedView), findsNothing);
  });

  // ======== シナリオ 4: mini view tap -> onStowStateChanged(expanded) ========
  testWidgets('4. mini view tap で onStowStateChanged(expanded) が発火', (tester) async {
    final persistence =
        _SyncPersistenceService(notes: [_seedNote(stow: StowState.mini)]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController();

    final received = <StowState>[];
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onStowStateChanged: (next) async {
        received.add(next);
      },
    ));
    await tester.pump();
    expect(find.byType(NoteMiniView), findsOneWidget);

    // mini view を tap (GestureDetector.onTap -> onStowStateChange(expanded))
    // 注: 外側 DragToMoveArea が GestureDetector(onDoubleTap, onPanStart) を持つ
    // ため、内側 TapGestureRecognizer は kDoubleTapTimeout (300ms) 待たないと
    // onTap を fire しない。pump(350ms) で double-tap 待ちを clear する。
    // さらに _requestStow 内部の Future.delayed(220ms) があるため、合計 ~600ms
    // 進めて finally の endTransition まで確実に走らせる。
    await tester.tap(find.byType(NoteMiniView));
    await tester.pump(const Duration(milliseconds: 350)); // double-tap timeout
    await tester.pump(const Duration(milliseconds: 300)); // Future.delayed(220ms) + slack

    // callback が expanded で発火
    expect(received, [StowState.expanded]);
    // setFrame が新サイズ (160x120) で呼ばれた
    expect(controller.setFrameCalls, isNotEmpty);
    expect(controller.setFrameCalls.first.width, 160);
    expect(controller.setFrameCalls.first.height, 120);
    // state も expanded
    final state = container.read(noteWindowNotifierProvider).value!;
    expect(state.note.stowState, StowState.expanded);
    // transition lock は finally で release 済
    expect(
      container.read(noteTransitionStartProvider).containsKey('n-shell-1'),
      isFalse,
    );

    await tester.pump(const Duration(milliseconds: 300));
  });

  // ======== シナリオ 5: 連打ガード ========
  testWidgets(
      '5. 進行中の transition lock 中は beginTransition() が false を返して連打を弾く',
      (tester) async {
    // 注: 1 回 tap した直後の同期 frame で UI は expanded view に切り替わるため、
    // 「2 回 mini を tap」の literal な再現は (NoteMiniView が消えるため) 不可。
    // 代わりに B-1 不変条件「進行中は beginTransition() が false」を直接検証する。
    // これは実装上の連打ガードロジックそのもの。
    final persistence =
        _SyncPersistenceService(notes: [_seedNote(stow: StowState.mini)]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController();

    var ipcCount = 0;
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onStowStateChanged: (next) async {
        ipcCount++;
      },
    ));
    await tester.pump();

    // 1 回目の tap -> DoubleTap timeout 待ち (300ms) -> onTap fire ->
    // _requestStow 内部 Future.delayed(220ms) await 中 = lock 張りっぱなし。
    await tester.tap(find.byType(NoteMiniView));
    // 350ms = double-tap timeout (300ms) clear + onTap microtask flush。
    // _requestStow は ~T=300 で start し、microtasks 完了後 Future.delayed(220ms)
    // 待ち (timer at T=520ms)。pump は T=350 で止まる -> lock 張りっぱなし。
    await tester.pump(const Duration(milliseconds: 350));

    // この時点で transitions に noteId が記録されている (= lock 張りっぱなし)
    final transitions = container.read(noteTransitionStartProvider.notifier);
    expect(
      container.read(noteTransitionStartProvider).containsKey('n-shell-1'),
      isTrue,
      reason: '1 回目 tap 直後は transition lock が張られているはず',
    );
    // 連打ガード: 進行中なので beginTransition は false を返す
    expect(
      transitions.beginTransition('n-shell-1'),
      isFalse,
      reason: '進行中の noteId に対して beginTransition は false を返すべき',
    );

    // 完了 (Future.delayed 解除 + finally) を待つ
    await tester.pump(const Duration(milliseconds: 300));
    expect(ipcCount, 1, reason: 'IPC は 1 回のみ');
    expect(
      container.read(noteTransitionStartProvider).containsKey('n-shell-1'),
      isFalse,
      reason: 'finally で endTransition が走り lock release 済',
    );

    await tester.pump(const Duration(milliseconds: 300));
  });

  // ======== シナリオ 6: setFrame throw でも UI crash せず state 反映 ========
  testWidgets('6. controller.setFrame throw でも UI 続行 + state は expanded',
      (tester) async {
    final persistence =
        _SyncPersistenceService(notes: [_seedNote(stow: StowState.mini)]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController(setFrameThrows: true);

    var stowChangeReceived = false;
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onStowStateChanged: (next) async {
        stowChangeReceived = true;
      },
    ));
    await tester.pump();

    await tester.tap(find.byType(NoteMiniView));
    await tester.pump(const Duration(milliseconds: 350)); // DoubleTap timeout
    await tester.pump(const Duration(milliseconds: 300)); // Future.delayed(220ms)

    // setFrame は呼ばれた (throw された)
    expect(controller.setFrameCalls.length, 1);
    // state は expanded に更新済 (updateStowState は setFrame の前に走る)
    final state = container.read(noteWindowNotifierProvider).value!;
    expect(state.note.stowState, StowState.expanded);
    // setFrame の throw は catch -> log のみ。後続 onStowStateChanged も呼ばれる
    expect(stowChangeReceived, isTrue);
    // transition lock は finally で release
    expect(
      container.read(noteTransitionStartProvider).containsKey('n-shell-1'),
      isFalse,
    );
    // UI crash していない (例外が test framework に上がっていない)
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 300));
  });

  // ======== シナリオ 7: callback throw でも finally で endTransition (B-1) ========
  testWidgets('7. onStowStateChanged callback throw でも finally で endTransition',
      (tester) async {
    // 注: onStowStateChange の throw は GestureDetector.onTap の fire-and-forget
    // future として discard され、test zone の handleUncaughtError に直接届く =
    // test framework の自動失敗を引き起こす (`tester.takeException()` でも捕捉
    // 不可)。これを避けるため、throwing callback を捕捉用 Completer 経由で
    // スイッチする: callback 内で error 用の Completer を completeError し、
    // 同期的に「捕捉済」フラグを立て、Future は明示的に catchError で抑える。
    // _requestStow への throw 経路は維持される (await で返ってくる Future が
    // 失敗するため、try/finally 契約は同じく検証できる)。
    final persistence =
        _SyncPersistenceService(notes: [_seedNote(stow: StowState.mini)]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController();

    Object? capturedCallbackError;
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onStowStateChanged: (next) {
        // 同期的に「呼ばれたよ」フラグ (= 連鎖の to-callback まで到達したことの証)
        // を立てた上で、await すると StateError で完了する Future を返す。
        capturedCallbackError ??= StateError('IPC failed');
        // 明示的に Future.error を返すと _requestStow.await が throw 経路に。
        return Future<void>.error(StateError('IPC failed'));
      },
    ));
    await tester.pump();

    // tap -> _requestStow start -> setFrame OK -> onStowStateChanged Future.error
    // -> _requestStow throw -> finally endTransition -> rethrow
    // rethrown error は GestureDetector.onTap (() => Future) で discard。
    // test zone に unhandled error として届くため、runZonedGuarded で吸収する。
    Object? unhandledError;
    await runZonedGuarded(() async {
      await tester.tap(find.byType(NoteMiniView));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 300));
    }, (error, stack) {
      // _requestStow の rethrow が discard された結果 (= "IPC failed")。期待値。
      unhandledError = error;
    });

    // 契約: throw でも callback は呼ばれた + finally で endTransition 走った
    expect(capturedCallbackError, isA<StateError>(),
        reason: 'callback は呼ばれているはず');
    expect(unhandledError, isA<StateError>(),
        reason: 'discard された throw は zone error として捕捉されるはず');

    expect(
      container.read(noteTransitionStartProvider).containsKey('n-shell-1'),
      isFalse,
      reason: 'callback throw でも finally で endTransition が走るべき (B-1 契約)',
    );
    // state は callback 前に更新済なので expanded
    final state = container.read(noteWindowNotifierProvider).value!;
    expect(state.note.stowState, StowState.expanded);

    await tester.pump(const Duration(milliseconds: 300));
  });

  // ======== シナリオ 8: 空ノート + archive -> onDeleteConfirmed + window.close ========
  testWidgets('8. 空ノートの archive button -> onDeleteConfirmed + window.close',
      (tester) async {
    // Phase 2c: _requestClose は空ノートを直接 onDeleteConfirmed 経路に流す
    // (確認 dialog 無し、Inbox 汚染防止)。
    final persistence = _SyncPersistenceService(notes: [
      _seedNote(stow: StowState.expanded, text: '', richText: ''),
    ]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController();

    var deleteCalled = 0;
    var panelClosedCalled = 0;
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onDeleteConfirmed: () async {
        deleteCalled++;
      },
      onPanelClosed: () async {
        panelClosedCalled++;
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(NoteExpandedView), findsOneWidget);

    final archive =
        find.byTooltip('Archive — close panel, note stays in Groups');
    expect(archive, findsOneWidget,
        reason: 'NoteTopBar の Archive button が描画されているはず');

    await tester.tap(archive, warnIfMissed: false);
    // DoubleTap timeout (300ms) clear + IconButton splash + async work
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 100));

    expect(deleteCalled, 1, reason: '空ノートは onDeleteConfirmed 経路 (Phase 2c)');
    expect(panelClosedCalled, 0, reason: '空ノートは onPanelClosed を呼ばない');
    expect(controller.closeCount, 1, reason: 'window.close が 1 回呼ばれる');

    await tester.pump(const Duration(milliseconds: 300));
  });

  // ======== シナリオ 9: 非空ノート + archive -> markPanelClosed + onPanelClosed ========
  testWidgets(
      '9. 非空ノートの archive button -> markPanelClosed + onPanelClosed + window.close',
      (tester) async {
    final persistence = _SyncPersistenceService(notes: [
      _seedNote(
        stow: StowState.expanded,
        text: 'real content here',
        richText: '[{"insert":"real content here\\n"}]',
      ),
    ]);
    final container = _buildContainer(
      persistence: persistence,
      args: const NoteWindowArguments(noteId: 'n-shell-1'),
    );
    addTearDown(container.dispose);
    final controller = _FakeWindowController();

    var deleteCalled = 0;
    var panelClosedCalled = 0;
    await tester.pumpWidget(_harness(
      container: container,
      controller: controller,
      onDeleteConfirmed: () async {
        deleteCalled++;
      },
      onPanelClosed: () async {
        panelClosedCalled++;
      },
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(NoteExpandedView), findsOneWidget);

    final archive =
        find.byTooltip('Archive — close panel, note stays in Groups');
    expect(archive, findsOneWidget);

    await tester.tap(archive, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 350)); // DoubleTap timeout
    await tester.pump(const Duration(milliseconds: 100));

    expect(panelClosedCalled, 1, reason: '非空は onPanelClosed 経路');
    expect(deleteCalled, 0, reason: '非空は delete 呼ばない');
    expect(controller.closeCount, 1, reason: 'window.close が 1 回呼ばれる');

    // markPanelClosed は isPanelOpen=false を即時 persist する
    final state = container.read(noteWindowNotifierProvider).value!;
    expect(state.note.isPanelOpen, isFalse,
        reason: 'markPanelClosed で isPanelOpen=false に更新されるはず');

    await tester.pump(const Duration(milliseconds: 300));
  });
}
