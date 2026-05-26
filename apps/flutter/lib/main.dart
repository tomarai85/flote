// Flote デスクトップ版エントリポイント。
//
// Sprint 3 で大幅改修:
//  - args[0] == 'multi_window' ならサブウィンドウ (ノート本体) を起動
//  - それ以外はメインウィンドウ (ListView + Tray + Hotkey + NoteWindowManager)
//  - Tray: macOS menubar / Windows systemtray (New Note / Settings / Groups / Quit)
//  - Hotkey: ⌥Space (Mac) / Alt+Space (Win) でノート新規作成
//  - NoteWindowManager: 各ノートを独立サブウィンドウで開く (desktop_multi_window)
//  - DesktopMultiWindow.setMethodHandler で子ウィンドウからの IPC を受信

import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
// Phase 2c: screen_retriever は window_manager の transitive dependency として既に
// pubspec.lock に固定済み (version 0.2.0)。直接 import しても追加依存は発生しない。
// ignore: depend_on_referenced_packages
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'models/app_settings.dart';
import 'models/sticky_note.dart';
import 'models/stow_state.dart';
import 'providers/app_settings.dart';
import 'providers/group_manager.dart';
import 'providers/history_manager.dart';
import 'providers/note_manager.dart';
import 'services/hotkey_service.dart';
import 'services/note_position_calculator.dart';
import 'services/note_window_manager.dart';
import 'services/tray_service.dart';
import 'services/window_style_channel.dart';
import 'theme/tokens.dart';
import 'ui/app_shell.dart';
import 'ui/note_window/note_window_entry.dart';
import 'ui/settings/settings_window.dart';

/// アプリ起動エントリポイント。
///
/// Flutter 側の desktop_multi_window 仕様:
///  - メインウィンドウは args が空 (または 'multi_window' 以外) で起動
///  - サブウィンドウは args = ['multi_window', '<id>', '<json>'] で起動
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  if (args.isNotEmpty && args.first == 'multi_window') {
    // サブウィンドウモード。
    final windowId = int.parse(args[1]);
    final arguments = _decodeArgs(args.length > 2 ? args[2] : '{}');
    runNoteWindow(windowId: windowId, arguments: arguments);
    return;
  }

  // メインウィンドウモード。
  await _initMainWindow();

  runApp(const ProviderScope(child: FloteApp()));
}

Map<String, dynamic> _decodeArgs(String raw) {
  if (raw.isEmpty) {
    return const <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
  } catch (error) {
    debugPrint('main: failed to decode sub-window args: $error');
  }
  return const <String, dynamic>{};
}

Future<void> _initMainWindow() async {
  await windowManager.ensureInitialized();
  const initialOptions = WindowOptions(
    size: Size(480, 640),
    minimumSize: Size(320, 400),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: 'Flote',
  );
  await windowManager.waitUntilReadyToShow(initialOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // 旧バインディングをクリア (dev reload 時の重複対策)。
  await hotKeyManager.unregisterAll();
}

/// ルート Widget。
class FloteApp extends ConsumerStatefulWidget {
  const FloteApp({super.key});

  @override
  ConsumerState<FloteApp> createState() => _FloteAppState();
}

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

class _FloteAppState extends ConsumerState<FloteApp> with WindowListener {
  final TrayService _tray = TrayService();
  final NoteWindowManager _noteWindows = NoteWindowManager();
  final WindowStyleChannel _windowStyle = WindowStyleChannel();
  bool _servicesBooted = false;
  bool _isSettingsOpen = false;

  HotkeyService get _hotkey => ref.read(hotkeyServiceProvider);

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    // 子ウィンドウからの IPC ハンドラ。Feature 3.5 で stowState 変更や
    // text 更新をメインの NoteManager state に反映する。
    DesktopMultiWindow.setMethodHandler(_handleSubWindowMethod);

    // J-1: macOS 側の NSWindow.didMove / didEndLiveResize を購読し、
    // 実座標/サイズを NoteManager に永続化する。併せてサブ engine に
    // IPC で push し、サブ側 NoteWindowNotifier.updatePosition/updateSize を呼ばせる。
    _windowStyle.startListeningToNative(
      onFrameChanged: _handleNoteWindowFrameChanged,
    );

    // build 完了後にサービス類を起動する (ref.read 安定確保)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootServices();
    });
  }

  Future<void> _bootServices() async {
    if (_servicesBooted) return;
    _servicesBooted = true;

    // Tray (Feature 3.6)。
    try {
      await _tray.initialize(
        onNewNote: _handleCreateNoteFromTray,
        onOpenSettings: _handleOpenSettings,
        onOpenGroups: _handleOpenGroups,
        onQuit: _handleQuitFromTray,
      );
    } catch (error) {
      debugPrint('TrayService.initialize failed: $error');
    }

    // Hotkey (Feature 3.7 + Sprint 5 Round 2 リバインド反映)。
    try {
      await _registerHotkeysFromSettings();
    } catch (error) {
      debugPrint('HotkeyService register failed: $error');
    }

    // 保存済みの isPanelOpen=true ノートを再表示する (Feature 3.1 の位置復元)。
    try {
      final notes = await ref.read(noteManagerProvider.future);
      for (final note in notes.where((n) => n.isPanelOpen)) {
        await _noteWindows.openWindowForNote(note);
      }
    } catch (error) {
      debugPrint('restore open notes failed: $error');
    }
  }

  @override
  void dispose() {
    // M0 audit fix: hot reload 時に initState で登録した IPC closure が
    // 残存しないように null で解除。
    DesktopMultiWindow.setMethodHandler(null);
    windowManager.removeListener(this);
    _windowStyle.stopListeningToNative();
    _hotkey.unregisterAll();
    _tray.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() async {
    try {
      await ref.read(noteManagerProvider.future);
      await ref.read(noteManagerProvider.notifier).flushSaveNow();
    } catch (_) {}
    try {
      await ref.read(groupManagerProvider.future);
      await ref.read(groupManagerProvider.notifier).flushSaveNow();
    } catch (_) {}
    // Sprint 5: AppSettings と History の pending save も flush する。
    try {
      await ref.read(appSettingsProvider.future);
      await ref.read(appSettingsProvider.notifier).flushSaveNow();
    } catch (_) {}
    try {
      await ref.read(historyManagerProvider.future);
      await ref.read(historyManagerProvider.notifier).flushSaveNow();
    } catch (_) {}

    await _noteWindows.closeAll();
    await _hotkey.unregisterAll();
    await _tray.dispose();

    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  /// Tray "New Note" から呼ばれる。
  Future<void> _handleCreateNoteFromTray() async {
    await _createNoteAndOpenWindow();
  }

  /// Hotkey (⌥Space / Alt+Space) から呼ばれる。
  Future<void> _handleCreateNoteFromHotkey() async {
    await _createNoteAndOpenWindow();
  }

  /// AppSettings.customShortcuts を参照し、3 スロットのホットキーを再登録する。
  ///
  /// ユーザーが Settings > Shortcuts でリバインドを保存した後に再呼び出しすれば
  /// 旧バインドを解除して新しい組み合わせを登録する。
  Future<void> _registerHotkeysFromSettings() async {
    AppSettings appSettings;
    try {
      // AsyncNotifier なので future を確実に解決させる。
      appSettings = await ref.read(appSettingsProvider.future);
    } catch (error) {
      debugPrint('AppSettings load failed (using defaults): $error');
      appSettings = AppSettings.defaults();
    }

    Future<void> registerOne(HotkeySlot slot, HotkeyCallback onTrigger) async {
      final raw = appSettings.customShortcuts[slot.slotKey];
      final combo = (raw != null ? HotkeyCombo.tryParse(raw) : null) ??
          HotkeyCombo.tryParse(slot.defaultCombo());
      if (combo == null) return;
      await _hotkey.registerSlot(
        slot: slot,
        combo: combo,
        onTrigger: onTrigger,
      );
    }

    await registerOne(HotkeySlot.newNote, _handleCreateNoteFromHotkey);
    await registerOne(HotkeySlot.openGroups, _handleOpenGroupsHotkey);
    await registerOne(HotkeySlot.archive, _handleArchiveHotkey);
  }

  void _handleOpenGroupsHotkey() {
    _handleOpenGroups();
  }

  void _handleArchiveHotkey() {
    // archive は「アクティブなノートウィンドウを閉じる」動作。MVP では
    // 全サブウィンドウを閉じる単純版 (フォーカス中ウィンドウ判定は将来実装)。
    // ユーザーの OS では ⌘W がアクティブウィンドウを閉じるので、実用上は
    // OS 側のショートカットで十分だが、Flote 内部の確定動作としても用意する。
    unawaited(_noteWindows.closeAll());
  }

  Future<void> _createNoteAndOpenWindow() async {
    try {
      // Phase 2c 修正 1: SwiftUI 踏襲の「画面中央 + ジッター配置」。
      // 既存実装は positionX/Y=0 (画面左上) だったため、macOS の全ディスプレイで
      // ノートが左上に固まる現象があった。
      final visibleFrame = await _fetchPrimaryVisibleFrame();
      final offset = calculateNewNotePosition(visibleFrame: visibleFrame);
      final note = await ref.read(noteManagerProvider.notifier).createNote(
            positionX: offset.dx,
            positionY: offset.dy,
          );
      await _noteWindows.openWindowForNote(note);
    } catch (error) {
      debugPrint('createNote failed: $error');
    }
  }

  /// Primary display の visible frame を取得する。
  ///
  /// screen_retriever の `getPrimaryDisplay()` は `visibleSize` / `visiblePosition` を
  /// 返す。visibleSize はメニューバー/タスクバーを除いたサイズ。取得失敗時は
  /// `defaultVisibleFrame()` (1440x900) にフォールバックしてクラッシュを防ぐ。
  Future<Rect> _fetchPrimaryVisibleFrame() async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final size = display.visibleSize ?? display.size;
      final origin = display.visiblePosition ?? Offset.zero;
      return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
    } catch (error) {
      debugPrint('screenRetriever.getPrimaryDisplay failed: $error');
      return defaultVisibleFrame();
    }
  }

  Future<void> _handleOpenSettings() async {
    // Sprint 5 Feature 5.4: Navigator push で Settings 画面を表示。
    // 別ウィンドウではなくメインウィンドウ内での全画面遷移。
    await windowManager.show();
    await windowManager.focus();
    final navigator = _rootNavigatorKey.currentState;
    if (navigator == null) return;
    // 既に Settings が開いているなら重複遷移しない。
    if (_isSettingsOpen) return;
    _isSettingsOpen = true;
    try {
      await navigator.push<void>(
        MaterialPageRoute(
          fullscreenDialog: true,
          settings: const RouteSettings(name: '/settings'),
          builder: (ctx) => SettingsWindow(
            onRequestClose: () => Navigator.of(ctx).maybePop(),
            onReloadHotkeys: _registerHotkeysFromSettings,
          ),
        ),
      );
    } finally {
      _isSettingsOpen = false;
      // Settings を閉じる時に pending save を flush する (spec 要件)。
      try {
        await ref.read(appSettingsProvider.notifier).flushSaveNow();
      } catch (_) {}
      try {
        await ref.read(historyManagerProvider.notifier).flushSaveNow();
      } catch (_) {}
    }
  }

  Future<void> _handleOpenGroups() async {
    // Groups タブを直接開く: Settings を開いて Groups タブを初期選択にする。
    // 現状 Settings は常に General から始まるため、Settings を開くだけの MVP。
    await _handleOpenSettings();
  }

  Future<void> _handleQuitFromTray() async {
    // 保存 flush してウィンドウ全閉じ → アプリ終了。
    try {
      await ref.read(noteManagerProvider.notifier).flushSaveNow();
    } catch (_) {}
    try {
      await ref.read(groupManagerProvider.notifier).flushSaveNow();
    } catch (_) {}
    try {
      await ref.read(appSettingsProvider.notifier).flushSaveNow();
    } catch (_) {}
    try {
      await ref.read(historyManagerProvider.notifier).flushSaveNow();
    } catch (_) {}
    await _noteWindows.closeAll();
    await _hotkey.unregisterAll();
    await _tray.dispose();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  /// J-1: macOS 側 NSWindow.didMove / didEndLiveResize から受けたフレーム情報を
  /// メインの NoteManager に永続化し、対応するサブ engine にも IPC で push する。
  void _handleNoteWindowFrameChanged(NoteWindowFrameEvent event) {
    // unawaited: main thread をブロックしない。エラーは吸収。
    _applyNoteWindowFrameChange(event);
  }

  Future<void> _applyNoteWindowFrameChange(
    NoteWindowFrameEvent event,
  ) async {
    // 1) メイン側 NoteManager に永続化。
    try {
      await ref.read(noteManagerProvider.future);
      final notifier = ref.read(noteManagerProvider.notifier);
      await notifier.updatePosition(event.noteId, event.x, event.y);
      if (event.width != null && event.height != null) {
        await notifier.updateSize(event.noteId, event.width!, event.height!);
      }
    } catch (error) {
      debugPrint('NoteManager updatePosition/updateSize failed: $error');
    }

    // 2) 該当サブ engine に IPC で push して、サブの NoteWindowNotifier state を
    //    同期させる (次回 persist で書き直されるが、それまで UI の値が古いのを防ぐ)。
    final windowId = _noteWindows.windowIdForNote(event.noteId);
    if (windowId == null) {
      return;
    }
    final payload = <String, Object?>{
      'noteId': event.noteId,
      'x': event.x,
      'y': event.y,
      if (event.width != null) 'width': event.width,
      if (event.height != null) 'height': event.height,
    };
    try {
      await DesktopMultiWindow.invokeMethod(
        windowId,
        'noteWindow.frameSync',
        jsonEncode(payload),
      );
    } catch (error) {
      debugPrint('frameSync push to sub $windowId failed: $error');
    }
  }

  /// サブウィンドウから届く IPC method を処理する。
  Future<Object?> _handleSubWindowMethod(
    MethodCall call,
    int fromWindowId,
  ) async {
    final noteId = _noteWindows.noteIdForWindow(fromWindowId);
    switch (call.method) {
      case 'noteWindow.stowStateChanged':
        if (noteId == null) return null;
        final payload = _decodeArgs(call.arguments?.toString() ?? '{}');
        final next = parseStowState(payload['stowState'] as String? ?? '');
        try {
          await ref
              .read(noteManagerProvider.notifier)
              .updateStowState(noteId, next);
        } catch (error) {
          debugPrint('updateStowState from sub failed: $error');
        }
        return null;
      case 'noteWindow.panelClosed':
        if (noteId == null) return null;
        try {
          await ref
              .read(noteManagerProvider.notifier)
              .setPanelOpen(noteId, false);
        } catch (error) {
          debugPrint('setPanelOpen false from sub failed: $error');
        }
        return null;
      case 'noteWindow.noteUpdated':
        // M0 audit fix 2026-05-10 (single-writer): サブから note 全体 payload を
        // 受け取り、main 側 state を partial update + debounce save する。
        // 旧実装は ref.invalidate(noteManagerProvider) で全件再読込していたが、
        // pending debounce save を cancel して text loss を起こす race があった。
        if (noteId == null) return null;
        try {
          final payload = _decodeArgs(call.arguments?.toString() ?? '{}');
          final noteJson = payload['note'];
          if (noteJson is! Map) return null;
          await ref.read(noteManagerProvider.future);
          final updated = StickyNote.fromJson(
            Map<String, dynamic>.from(noteJson),
          );
          await ref
              .read(noteManagerProvider.notifier)
              .applySubWindowUpdate(updated);
        } catch (error) {
          debugPrint('apply sub window update failed: $error');
        }
        return null;
      case 'noteWindow.deleteNote':
        // Sprint 4 Feature 4.3 + Sprint 5 Feature 5.5: サブウィンドウで削除が確定
        // したのでメイン側で deleteNote + history 追加を実行する。
        if (noteId == null) return null;
        try {
          // M0 audit fix: AsyncNotifier loading 中だと noteById が null を返し
          // history 漏れする。先に future を await して state を確定させる。
          await ref.read(noteManagerProvider.future);
          // 削除前に対象ノートの情報を history に送る (M9: History 管理)。
          final notifier = ref.read(noteManagerProvider.notifier);
          final target = notifier.noteById(noteId);
          if (target != null) {
            try {
              await ref
                  .read(historyManagerProvider.notifier)
                  .addFromDeletedNote(target);
            } catch (historyError) {
              debugPrint('add history failed: $historyError');
            }
          }
          await notifier.deleteNote(noteId);
          await _noteWindows.closeWindowForNote(noteId);
        } catch (error) {
          debugPrint('deleteNote from sub failed: $error');
        }
        return null;
      case 'noteWindow.organizeRun':
        // Sprint 5 Feature 5.1: サブウィンドウから Organize 実行要求。
        // 実際の HTTP 呼び出しはサブ engine 側 (organizeRunnerProvider) で
        // 行っているため、メイン engine が受け取っても何もしない。
        // この IPC は将来的にメインで OrganizeRunner を共有する設計に
        // 移行した際の hook point として予約。
        return null;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flote',
      navigatorKey: _rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ja'),
        Locale('en'),
      ],
      locale: const Locale('ja'),
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: ColorTokens.accent,
          brightness: Brightness.light,
          surface: ColorTokens.surface,
        ),
        scaffoldBackgroundColor: ColorTokens.surface,
        // Feature 6.4: Material Theme に FloteTheme (ThemeExtension) を注入。
        // 以降のコードは `Theme.of(context).floteTheme` でトークン参照できる。
        extensions: const <ThemeExtension<dynamic>>[
          FloteTheme.standard,
        ],
      ),
      home: _HomeShell(
        noteWindows: _noteWindows,
      ),
    );
  }
}

/// main window の Home。AppShell を表示しつつ、サブウィンドウ操作を橋渡しする。
class _HomeShell extends ConsumerWidget {
  const _HomeShell({required this.noteWindows});

  final NoteWindowManager noteWindows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppShell(
      onOpenNote: (StickyNote note) async {
        await noteWindows.openWindowForNote(note);
      },
    );
  }
}
