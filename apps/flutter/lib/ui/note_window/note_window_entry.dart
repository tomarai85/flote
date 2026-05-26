// サブウィンドウ (ノート本体ウィンドウ) のエントリポイント。
//
// main.dart から次のように呼ぶ:
//
//   if (args.isNotEmpty && args[0] == 'multi_window') {
//     final windowId = int.parse(args[1]);
//     final arguments = jsonDecode(args[2]) as Map<String, dynamic>;
//     runNoteWindow(windowId: windowId, arguments: arguments);
//     return;
//   }
//
// このエントリはサブウィンドウ 1 つ (ノート 1 つ) に対応する。
// main isolate (メインウィンドウ) とは別の Flutter engine / isolate で動くため、
// Riverpod state もここで独立したコンテナを作る。
//
// Sprint 3 Round 1 (J-1 / J-2 修正):
//   - noteUpdated IPC をメインへ送信 (persist 成功時)
//   - panelClosed IPC をメインへ送信 (close ボタン押下時)
//   - メインからの noteWindow.frameSync IPC を受け取り、サブの NoteWindowNotifier
//     .updatePosition / updateSize を呼ぶ (DragToMoveArea の結果同期)

import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/stow_state.dart';
import '../../theme/tokens.dart';
import 'note_window_model.dart';
import 'note_window_shell.dart';

/// サブウィンドウ Flutter アプリを起動する。
void runNoteWindow({
  required int windowId,
  required Map<String, dynamic> arguments,
}) {
  WidgetsFlutterBinding.ensureInitialized();

  final args = NoteWindowArguments.fromJson(arguments);
  final controller = WindowController.fromWindowId(windowId);

  runApp(
    ProviderScope(
      overrides: [
        noteWindowArgumentsProvider.overrideWithValue(args),
        // M0 audit fix 2026-05-10 (single-writer): 編集後の StickyNote 全体を
        // payload として main へ送信。main 側で state 更新 + 永続化を行う
        // (Sub engine は file を書かない)。
        noteWindowUpdatedNotifierProvider.overrideWithValue(
          (note) async {
            try {
              await DesktopMultiWindow.invokeMethod(
                0,
                'noteWindow.noteUpdated',
                jsonEncode({
                  'noteId': note.id,
                  'note': note.toJson(),
                }),
              );
            } catch (error) {
              debugPrint('noteUpdated invoke failed: $error');
            }
          },
        ),
      ],
      child: _NoteWindowApp(controller: controller),
    ),
  );
}

class _NoteWindowApp extends ConsumerStatefulWidget {
  const _NoteWindowApp({required this.controller});

  final WindowController controller;

  @override
  ConsumerState<_NoteWindowApp> createState() => _NoteWindowAppState();
}

class _NoteWindowAppState extends ConsumerState<_NoteWindowApp> {
  @override
  void initState() {
    super.initState();
    // J-1: メインから push される noteWindow.frameSync を受け取り、
    //      サブの NoteWindowNotifier.updatePosition / updateSize を呼ぶ。
    //      desktop_multi_window は 1 engine に 1 ハンドラなので、サブ engine
    //      固有で登録して問題なし。
    DesktopMultiWindow.setMethodHandler(_handleMainToSubMethod);
  }

  @override
  void dispose() {
    // setMethodHandler(null) で外す。
    try {
      DesktopMultiWindow.setMethodHandler(null);
    } catch (_) {
      // 無視。
    }
    super.dispose();
  }

  Future<Object?> _handleMainToSubMethod(
    MethodCall call,
    int fromWindowId,
  ) async {
    switch (call.method) {
      case 'noteWindow.frameSync':
        final payload = _decodeArgs(call.arguments);
        final x = payload['x'];
        final y = payload['y'];
        final width = payload['width'];
        final height = payload['height'];
        final notifier = ref.read(noteWindowNotifierProvider.notifier);
        try {
          if (x is num && y is num) {
            await notifier.updatePosition(x.toDouble(), y.toDouble());
          }
          if (width is num && height is num) {
            await notifier.updateSize(width.toDouble(), height.toDouble());
          }
        } catch (error) {
          debugPrint('frameSync apply to Notifier failed: $error');
        }
        return null;
      case 'noteWindow.pushNote':
        // 予約: メインから完全な note JSON を push する用途 (Sprint 5 で活用)。
        return null;
      default:
        return null;
    }
  }

  Map<String, Object?> _decodeArgs(Object? raw) {
    if (raw is Map) {
      return Map<String, Object?>.from(raw);
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return Map<String, Object?>.from(decoded);
        }
      } catch (_) {
        // 無視、空 map を返す。
      }
    }
    return const <String, Object?>{};
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flote Note',
      debugShowCheckedModeBanner: false,
      // flutter_quill のメニュー等のローカライズ配信 (MVP は英語基盤 + 日本語 UI)。
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
        scaffoldBackgroundColor: Colors.transparent,
        // Feature 6.4: サブウィンドウ engine にも FloteTheme を注入。
        extensions: const <ThemeExtension<dynamic>>[
          FloteTheme.standard,
        ],
      ),
      home: Builder(
        builder: (context) {
          return NoteWindowShell(
            windowController: widget.controller,
            onStowStateChanged: (StowState next) async {
              // メイン (windowId=0) に IPC で通知。
              try {
                await DesktopMultiWindow.invokeMethod(
                  0,
                  'noteWindow.stowStateChanged',
                  jsonEncode({'stowState': next.name}),
                );
              } catch (error) {
                debugPrint('stowStateChanged invoke failed: $error');
              }
            },
            onPanelClosed: () async {
              // メイン (windowId=0) に 閉じる通知 (J-2)。
              // メイン側の NoteManager.setPanelOpen(id, false) を呼ばせ、
              // ListView の state 矛盾を防ぐ。
              try {
                await DesktopMultiWindow.invokeMethod(
                  0,
                  'noteWindow.panelClosed',
                  jsonEncode(<String, Object?>{}),
                );
              } catch (error) {
                debugPrint('panelClosed invoke failed: $error');
              }
            },
            onDeleteConfirmed: () async {
              // Sprint 4 Feature 4.3: 削除確定の IPC 通知。
              // メイン側の NoteManager.deleteNote を呼ばせる。
              try {
                await DesktopMultiWindow.invokeMethod(
                  0,
                  'noteWindow.deleteNote',
                  jsonEncode(<String, Object?>{}),
                );
              } catch (error) {
                debugPrint('deleteNote invoke failed: $error');
              }
            },
          );
        },
      ),
    );
  }
}

/// サブウィンドウが持つタイトル。MainFlutterWindow.swift の
/// setWindowLevelFloating(title:) が名前で探すので一意に。
/// main.dart / NoteWindowManager から参照される。
String titleForNoteWindow(String noteId) => 'Flote Note $noteId';
