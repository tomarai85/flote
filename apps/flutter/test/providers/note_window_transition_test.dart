// Sprint 3 Feature 3.5 連打ガードテスト。
//
// - beginTransition: 初回 true、既に進行中なら false
// - endTransition: フラグを解放、以後の beginTransition は true
// - 時間経過で自動解除 (guardDuration 経過)

import 'package:flote_desktop/providers/note_window_transition.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NoteTransitionStateNotifier', () {
    test('初回の beginTransition は true を返す', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(noteTransitionStartProvider.notifier);
      expect(notifier.beginTransition('note-1'), isTrue);
      expect(notifier.isTransitioning('note-1'), isTrue);
    });

    test('進行中の noteId に対する 2 回目の beginTransition は false', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(noteTransitionStartProvider.notifier);
      expect(notifier.beginTransition('note-1'), isTrue);
      expect(notifier.beginTransition('note-1'), isFalse);
    });

    test('endTransition 後は再度 beginTransition できる', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(noteTransitionStartProvider.notifier);
      notifier.beginTransition('note-1');
      notifier.endTransition('note-1');
      expect(notifier.isTransitioning('note-1'), isFalse);
      expect(notifier.beginTransition('note-1'), isTrue);
    });

    test('異なる noteId 同士は干渉しない', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(noteTransitionStartProvider.notifier);
      expect(notifier.beginTransition('note-1'), isTrue);
      expect(notifier.beginTransition('note-2'), isTrue);
      expect(notifier.isTransitioning('note-1'), isTrue);
      expect(notifier.isTransitioning('note-2'), isTrue);
    });

    test('guardDuration 経過後は自動的に解除される', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(noteTransitionStartProvider.notifier);
      notifier.beginTransition('note-1');
      await Future<void>.delayed(
        NoteTransitionStateNotifier.guardDuration + const Duration(milliseconds: 50),
      );
      expect(notifier.isTransitioning('note-1'), isFalse);
      expect(notifier.beginTransition('note-1'), isTrue);
    });
  });
}
