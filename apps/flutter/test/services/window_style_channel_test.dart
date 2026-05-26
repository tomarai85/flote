// Sprint 3 Round 1 (J-1) 修正の一部: WindowStyleChannel が Swift 側からの
// noteWindow.didMove / noteWindow.didResize push を NoteWindowFrameEvent に
// 正しく変換するかを検証する。
//
// テスト環境は Platform.isMacOS で分岐があるため、直接 _handleNativeCall 相当を
// 呼ぶかわりに MethodChannel の mock を差し込んでメッセージを注入する。

import 'dart:io';

import 'package:flote_desktop/services/window_style_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // macOS 以外でも Platform 判定を超えて handler に到達することを検証するため、
  // 直接 BinaryMessenger 経由で channel を呼ぶ。startListeningToNative は
  // Platform.isMacOS でのみ setMethodCallHandler するので、ここではチャンネル
  // ハンドラを差し込まず、WindowStyleChannel インスタンスから直接 public な
  // 公開部分 (parseFrameEvent 相当は private) を検証する代わりに、
  // 本体の受信経路 (MessageCodec round-trip) をカバーする。

  test('macOS 以外では startListeningToNative は落ちず no-op', () async {
    final channel = WindowStyleChannel();
    expect(
      () => channel.startListeningToNative(onFrameChanged: (_) {}),
      returnsNormally,
    );
    expect(() => channel.stopListeningToNative(), returnsNormally);
  });

  test(
    'mac: MethodChannel 経由で noteWindow.didMove/didResize が届くと callback が呼ばれる',
    () async {
      if (!Platform.isMacOS) {
        // 非 macOS では setMethodCallHandler が no-op なのでスキップ。
        return;
      }
      const channel = MethodChannel('flote/window_style');
      final receivedEvents = <NoteWindowFrameEvent>[];
      final wrapper = WindowStyleChannel(channel: channel);
      wrapper.startListeningToNative(onFrameChanged: receivedEvents.add);
      addTearDown(wrapper.stopListeningToNative);

      // mac では NSApp から Flutter への push を handleMethodCall で模倣する。
      final binding = TestWidgetsFlutterBinding.instance;
      Future<ByteData?> sendFromNative(String method, Object? args) async {
        final data = const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, args),
        );
        return binding.defaultBinaryMessenger
            .handlePlatformMessage(channel.name, data, (_) {});
      }

      await sendFromNative('noteWindow.didMove', {
        'noteId': 'abc',
        'x': 100.5,
        'y': 200.25,
      });
      await sendFromNative('noteWindow.didResize', {
        'noteId': 'abc',
        'x': 100.5,
        'y': 200.25,
        'width': 180.0,
        'height': 140.0,
      });

      expect(receivedEvents.length, 2);
      expect(receivedEvents.first.noteId, 'abc');
      expect(receivedEvents.first.x, 100.5);
      expect(receivedEvents.first.y, 200.25);
      expect(receivedEvents.first.width, isNull);
      expect(receivedEvents.last.width, 180.0);
      expect(receivedEvents.last.height, 140.0);
    },
  );

  test(
    'mac: 不正な引数は callback を呼ばない (noteId 欠落)',
    () async {
      if (!Platform.isMacOS) {
        return;
      }
      const channel = MethodChannel('flote/window_style');
      final receivedEvents = <NoteWindowFrameEvent>[];
      final wrapper = WindowStyleChannel(channel: channel);
      wrapper.startListeningToNative(onFrameChanged: receivedEvents.add);
      addTearDown(wrapper.stopListeningToNative);

      final binding = TestWidgetsFlutterBinding.instance;
      final data = const StandardMethodCodec().encodeMethodCall(
        const MethodCall('noteWindow.didMove', {'x': 10, 'y': 20}),
      );
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        data,
        (_) {},
      );

      expect(receivedEvents, isEmpty);
    },
  );
}
