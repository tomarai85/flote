// Phase 2c 修正 2: 空ノートを閉じたら自動削除ロジックの単体テスト。
//
// `isNoteEmptyForCloseDeletion(text, richText)` が SwiftUI `NoteManager.archiveNote`
// の「空ノートは Inbox を汚染しないよう削除」判定と等価であることを検証する。

import 'package:flote_desktop/ui/note_window/note_window_shell.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isNoteEmptyForCloseDeletion', () {
    test('text と richText 両方空なら true', () {
      expect(
        isNoteEmptyForCloseDeletion(text: '', richText: ''),
        isTrue,
      );
    });

    test('text が空白のみ かつ richText が空なら true', () {
      expect(
        isNoteEmptyForCloseDeletion(text: '   \n  \t', richText: ''),
        isTrue,
      );
    });

    test('text が空 かつ richText が改行のみ Delta なら true', () {
      expect(
        isNoteEmptyForCloseDeletion(
          text: '',
          richText: '[{"insert":"\\n"}]',
        ),
        isTrue,
      );
    });

    test('text が空白のみ かつ richText が空白改行 Delta なら true', () {
      expect(
        isNoteEmptyForCloseDeletion(
          text: '   ',
          richText: '[{"insert":"   \\n"}]',
        ),
        isTrue,
      );
    });

    test('text に実文字があれば richText が空でも false', () {
      expect(
        isNoteEmptyForCloseDeletion(text: 'hello', richText: ''),
        isFalse,
      );
    });

    test('richText に実文字があれば text が空でも false', () {
      expect(
        isNoteEmptyForCloseDeletion(
          text: '',
          richText: '[{"insert":"hello\\n"}]',
        ),
        isFalse,
      );
    });

    test('両方に実文字があれば false', () {
      expect(
        isNoteEmptyForCloseDeletion(
          text: 'hi',
          richText: '[{"insert":"hi\\n"}]',
        ),
        isFalse,
      );
    });
  });
}
