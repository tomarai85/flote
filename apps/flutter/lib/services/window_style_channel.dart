// Swift 側 (macOS の MainFlutterWindow.swift) に対する MethodChannel ラッパ。
//
// Sprint 3 / DD-9: macOS ではノートウィンドウを nonactivating + floating level に
// 設定し、現行 SwiftUI 版の「他アプリ作業中にクリックしてもアクティブ化されない」
// UX を踏襲する。
// Windows 側は std Flutter 実装のため no-op となる (Platform 判定で skip)。
//
// Sprint 3 Round 1 (J-1 修正):
//   macOS 側の NSWindow.didMove / didEndLiveResize 通知を Flutter に push する
//   受信 channel としても使う。メインの Flutter engine がサブウィンドウの
//   実座標/サイズを受け取って NoteManager.updatePosition / updateSize を呼ぶ。

import 'dart:io';

import 'package:flutter/services.dart';

/// macOS のメインウィンドウに仕掛けた MethodChannel 名。
/// macos/Runner/MainFlutterWindow.swift と同期すること。
const String _kChannelName = 'flote/window_style';

/// Swift 側から push されるメソッド名 (J-1)。
class WindowStyleMethods {
  WindowStyleMethods._();

  /// ノートウィンドウがドラッグで移動し終えた通知。
  /// 引数: {noteId: String, x: double, y: double}
  static const String noteWindowDidMove = 'noteWindow.didMove';

  /// ノートウィンドウがライブリサイズを終えた通知。
  /// 引数: {noteId: String, width: double, height: double, x: double, y: double}
  static const String noteWindowDidResize = 'noteWindow.didResize';
}

/// Swift 側から送られてくる位置更新イベント。
class NoteWindowFrameEvent {
  const NoteWindowFrameEvent({
    required this.noteId,
    required this.x,
    required this.y,
    this.width,
    this.height,
  });

  final String noteId;
  final double x;
  final double y;

  /// didMove では null。didResize では値が入る。
  final double? width;
  final double? height;
}

/// macOS のサブウィンドウ (desktop_multi_window が生成する NSWindow) に
/// `.floating` level と nonactivating 風 collectionBehavior を適用するための
/// Flutter 側インターフェース。
class WindowStyleChannel {
  WindowStyleChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_kChannelName);

  final MethodChannel _channel;

  /// Swift 側から push される didMove / didResize を購読するコールバック。
  /// main.dart の _FloteAppState で設定し、NoteManager.updatePosition/updateSize
  /// を呼ばせる。1 インスタンスで 1 ハンドラのみ保持する想定 (上書き可)。
  void Function(NoteWindowFrameEvent event)? _onWindowFrameChanged;

  /// Swift 側からの push を受ける準備。macOS 以外では no-op。
  /// テスト環境で呼ばれても落ちないよう ServicesBinding 未初期化エラーは吸収する。
  void startListeningToNative({
    required void Function(NoteWindowFrameEvent event) onFrameChanged,
  }) {
    _onWindowFrameChanged = onFrameChanged;
    if (!Platform.isMacOS) {
      return;
    }
    try {
      _channel.setMethodCallHandler(_handleNativeCall);
    } catch (error) {
      stderr.writeln(
        'WindowStyleChannel.setMethodCallHandler failed: $error',
      );
    }
  }

  /// テスト / 終了時用にハンドラを外す。
  void stopListeningToNative() {
    _onWindowFrameChanged = null;
    if (!Platform.isMacOS) {
      return;
    }
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {
      // 無視 (未登録 channel に null を set してもほぼ何も起きない)。
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case WindowStyleMethods.noteWindowDidMove:
        final event = _parseFrameEvent(call.arguments, includeSize: false);
        if (event != null) {
          _onWindowFrameChanged?.call(event);
        }
        return null;
      case WindowStyleMethods.noteWindowDidResize:
        final event = _parseFrameEvent(call.arguments, includeSize: true);
        if (event != null) {
          _onWindowFrameChanged?.call(event);
        }
        return null;
      default:
        return null;
    }
  }

  /// 引数 (Map) を NoteWindowFrameEvent に変換する。パターン外は null。
  NoteWindowFrameEvent? _parseFrameEvent(
    Object? arguments, {
    required bool includeSize,
  }) {
    if (arguments is! Map) {
      return null;
    }
    final noteId = arguments['noteId'];
    final x = arguments['x'];
    final y = arguments['y'];
    if (noteId is! String || noteId.isEmpty || x is! num || y is! num) {
      return null;
    }
    double? width;
    double? height;
    if (includeSize) {
      final w = arguments['width'];
      final h = arguments['height'];
      if (w is num) width = w.toDouble();
      if (h is num) height = h.toDouble();
    }
    return NoteWindowFrameEvent(
      noteId: noteId,
      x: x.toDouble(),
      y: y.toDouble(),
      width: width,
      height: height,
    );
  }

  /// macOS 以外では何もしない。macOS では現在開いている全てのサブウィンドウに
  /// floating level / canJoinAllSpaces / stationary / isMovableByWindowBackground
  /// を適用する。
  ///
  /// 例外は広く catch する (ServicesBinding 未初期化の StateError 等も想定、
  /// テスト環境で呼ばれても落ちないことを保証する)。
  Future<void> applyNonactivatingStyleToAllSubwindows() async {
    if (!Platform.isMacOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(
        'applyNonactivatingStyleToAllSubwindows',
      );
    } catch (error) {
      stderr.writeln(
        'WindowStyleChannel.applyNonactivatingStyleToAllSubwindows failed: $error',
      );
    }
  }

  /// タイトル一致で特定のウィンドウだけ floating level に上げる。
  /// macOS 以外は no-op。
  Future<void> setWindowLevelFloating(String windowTitle) async {
    if (!Platform.isMacOS) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setWindowLevelFloating', {
        'windowTitle': windowTitle,
      });
    } catch (error) {
      stderr.writeln('WindowStyleChannel.setWindowLevelFloating failed: $error');
    }
  }
}
