// NoteWindowManager: ノート 1 つ = サブウィンドウ 1 つ という前提で、
// desktop_multi_window プラグインを使ってウィンドウのライフサイクルを司る。
//
// Sprint 3 Feature 3.1 の中核。
//
// メインウィンドウ (main isolate) 側からこのクラスを呼んで
// DesktopMultiWindow.createWindow(...) で別ウィンドウを起動する。
// サブウィンドウ内の Flutter はメインとは別エンジンとして動作するため、
// Riverpod state は共有されない。データ同期は:
//   1. 起動時に noteId を引数として渡す (argumentsAsJson)
//   2. サブウィンドウは PersistenceService から直接読み書きする
//   3. 変更はサブ側が保存 → メインは再読込 (Sprint 5 で改善余地)
//
// ウィンドウ位置/サイズの保存:
//   - サブウィンドウが閉じられるときに現在の frame を JSON で保存
//   - 再度開くときに frame を復元
//   - desktop_multi_window の制約で位置取得は Swift platform channel 経由の余地あり
//     (MVP では前回の NoteManager 上の positionX/Y/width/height を使う)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../models/sticky_note.dart';
import '../models/stow_state.dart';
import 'window_style_channel.dart';

/// ウィンドウ状態 -> サイズ マッピング。
///
/// Phase 2 (SwiftUI 視覚踏襲):
/// - expanded: noteManager 上の width/height (既定 160x120、GoldenRatio.medium)
/// - rolledUp: 26px 薄型バー (幅は expanded と同じ 160)
/// - mini: 36x36 円形 (SwiftUI MiniNoteView 準拠、旧 48 から縮小)
///
/// 値は `DimensionTokens` に定数として持たせ、SwiftUI 側の変更を追従しやすくする。
({double width, double height}) windowSizeForState(
  StowState state,
  double expandedWidth,
  double expandedHeight,
) {
  switch (state) {
    case StowState.expanded:
      return (width: expandedWidth, height: expandedHeight);
    case StowState.rolledUp:
      return (width: expandedWidth, height: 26);
    case StowState.mini:
      return (width: 36, height: 36);
  }
}

/// サブウィンドウ内 Flutter から main へ送る IPC method 名。
class NoteWindowMethods {
  NoteWindowMethods._();

  /// サブウィンドウ側で StowState が切り替わったことを通知する。
  static const String stowStateChanged = 'noteWindow.stowStateChanged';

  /// サブウィンドウ側でノート本体が閉じられた (isPanelOpen = false)。
  static const String panelClosed = 'noteWindow.panelClosed';

  /// サブウィンドウ側でテキスト / 位置 / サイズが保存された。
  /// メイン側はこれを受けて NoteManager を reload する。
  static const String noteUpdated = 'noteWindow.noteUpdated';

  /// メインからサブへ: 現在のノート JSON を push する。
  static const String pushNote = 'noteWindow.pushNote';
}

/// NoteWindowManager: メインウィンドウからサブウィンドウを開閉するサービス。
class NoteWindowManager {
  NoteWindowManager({
    WindowStyleChannel? styleChannel,
    MultiWindowAdapter? adapter,
  }) : _styleChannel = styleChannel ?? WindowStyleChannel(),
       _adapter = adapter ?? const _RealMultiWindowAdapter();

  final WindowStyleChannel _styleChannel;
  final MultiWindowAdapter _adapter;

  /// noteId -> windowId のマッピング。同じノートのウィンドウが複数起動しないように。
  final Map<String, int> _openWindows = <String, int>{};

  /// 現在開いているウィンドウ数。
  @visibleForTesting
  int get openWindowCount => _openWindows.length;

  /// 指定ノートのウィンドウが既に開いているか。
  bool isOpen(String noteId) => _openWindows.containsKey(noteId);

  /// ノートに対応するサブウィンドウを開く。既に開いていればフォーカスする。
  /// 戻り値: 新規 or 既存の windowId。サポートされていない platform (テスト環境等) では null。
  Future<int?> openWindowForNote(StickyNote note) async {
    final existing = _openWindows[note.id];
    if (existing != null) {
      try {
        await _adapter.show(existing);
      } catch (error) {
        stderr.writeln('NoteWindowManager.show failed for $existing: $error');
      }
      return existing;
    }

    final payload = jsonEncode({
      'noteId': note.id,
      // 復元用の初期情報。サブウィンドウ側は最新版を persistence から読み直す。
      'initialText': note.text,
      'positionX': note.positionX,
      'positionY': note.positionY,
      'width': note.width,
      'height': note.height,
      'stowState': note.stowState.name,
    });

    int? windowId;
    try {
      windowId = await _adapter.createWindow(payload);
    } catch (error) {
      stderr.writeln('NoteWindowManager.createWindow failed: $error');
      return null;
    }

    if (windowId == null) {
      return null;
    }

    _openWindows[note.id] = windowId;

    try {
      final size = windowSizeForState(note.stowState, note.width, note.height);
      await _adapter.setTitle(windowId, _titleForNote(note));
      await _adapter.setFrame(
        windowId,
        left: note.positionX,
        top: note.positionY,
        width: size.width,
        height: size.height,
      );
      await _adapter.show(windowId);
    } catch (error) {
      stderr.writeln(
        'NoteWindowManager.setFrame/show failed for $windowId: $error',
      );
    }

    // macOS のみ、ネイティブ側で floating level + nonactivating collectionBehavior に差し替える。
    if (Platform.isMacOS) {
      await _styleChannel.applyNonactivatingStyleToAllSubwindows();
    }

    return windowId;
  }

  /// noteId のウィンドウを閉じる。ウィンドウ自体を dispose するため、
  /// StickyNote レコード自体には影響しない (isPanelOpen は呼び出し側で管理する想定)。
  Future<void> closeWindowForNote(String noteId) async {
    final windowId = _openWindows.remove(noteId);
    if (windowId == null) {
      return;
    }
    try {
      await _adapter.close(windowId);
    } catch (error) {
      stderr.writeln(
        'NoteWindowManager.closeWindow failed for $windowId: $error',
      );
    }
  }

  /// noteId のウィンドウサイズだけを変更する (3 状態遷移時にメイン側から呼ぶ)。
  Future<void> resizeForState(String noteId, StickyNote note) async {
    final windowId = _openWindows[noteId];
    if (windowId == null) {
      return;
    }
    final size = windowSizeForState(note.stowState, note.width, note.height);
    try {
      await _adapter.setFrame(
        windowId,
        left: note.positionX,
        top: note.positionY,
        width: size.width,
        height: size.height,
      );
    } catch (error) {
      stderr.writeln(
        'NoteWindowManager.resizeForState failed for $windowId: $error',
      );
    }
  }

  /// windowId -> noteId 逆引き。
  String? noteIdForWindow(int windowId) {
    for (final entry in _openWindows.entries) {
      if (entry.value == windowId) {
        return entry.key;
      }
    }
    return null;
  }

  /// noteId -> windowId 取得 (開いていなければ null)。J-1 でサブ engine に
  /// IPC push するために使う。
  int? windowIdForNote(String noteId) => _openWindows[noteId];

  /// 全ノートのウィンドウを閉じる (アプリ終了時用)。
  Future<void> closeAll() async {
    final ids = _openWindows.values.toList(growable: false);
    _openWindows.clear();
    for (final id in ids) {
      try {
        await _adapter.close(id);
      } catch (error) {
        stderr.writeln('NoteWindowManager.closeAll failed for $id: $error');
      }
    }
  }

  /// テスト用にウィンドウマップを直接差し替える。
  @visibleForTesting
  void registerForTest(String noteId, int windowId) {
    _openWindows[noteId] = windowId;
  }

  /// ノートウィンドウのタイトル (OS 上で Swift 側が一意に識別するために使う)。
  String _titleForNote(StickyNote note) => 'Flote Note ${note.id}';
}

/// desktop_multi_window をラップするアダプタ。テスト時は偽物を差し込める。
abstract class MultiWindowAdapter {
  const MultiWindowAdapter();

  /// arguments (JSON) を渡してサブウィンドウを作成し、window id を返す。
  Future<int?> createWindow(String argumentsAsJson);

  Future<void> setTitle(int windowId, String title);

  Future<void> setFrame(
    int windowId, {
    required double left,
    required double top,
    required double width,
    required double height,
  });

  Future<void> show(int windowId);

  Future<void> close(int windowId);
}

/// 実機用: desktop_multi_window パッケージを直接叩く。
class _RealMultiWindowAdapter extends MultiWindowAdapter {
  const _RealMultiWindowAdapter();

  @override
  Future<int?> createWindow(String argumentsAsJson) async {
    final window = await DesktopMultiWindow.createWindow(argumentsAsJson);
    return window.windowId;
  }

  @override
  Future<void> setTitle(int windowId, String title) async {
    await WindowController.fromWindowId(windowId).setTitle(title);
  }

  @override
  Future<void> setFrame(
    int windowId, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) async {
    await WindowController.fromWindowId(windowId).setFrame(
      Rect.fromLTWH(left, top, width, height),
    );
  }

  @override
  Future<void> show(int windowId) async {
    await WindowController.fromWindowId(windowId).show();
  }

  @override
  Future<void> close(int windowId) async {
    await WindowController.fromWindowId(windowId).close();
  }
}

