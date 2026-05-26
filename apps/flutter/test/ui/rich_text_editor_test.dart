// Sprint 4 Feature 4.1: rich_text_editor.dart の richTextToPlainText helper を検証。
//
// QuillEditor Widget 自体は platform plugin と FocusNode の都合で unit test が難しいため、
// top-level の純粋 dart 関数のみを対象にする。

import 'package:flote_desktop/ui/note_window/rich_text_editor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('richTextToPlainText は Delta JSON をプレーンテキストに変換する', () {
    const json = '[{"insert":"hello world\\n"}]';
    expect(richTextToPlainText(json), 'hello world');
  });

  test('richTextToPlainText は書式付き Delta でも insert だけ抜き出す', () {
    const json = '[{"insert":"bold","attributes":{"bold":true}},'
        '{"insert":" normal\\n"}]';
    expect(richTextToPlainText(json), 'bold normal');
  });

  test('richTextToPlainText は空文字で空を返す', () {
    expect(richTextToPlainText(''), '');
    expect(richTextToPlainText('   '), '');
  });

  test('richTextToPlainText は不正 JSON で空を返す', () {
    expect(richTextToPlainText('{not json}'), '');
    expect(richTextToPlainText('not-a-json-string'), '');
  });

  test('richTextToPlainText は List ではない JSON で空を返す', () {
    expect(richTextToPlainText('{"insert":"plain"}'), '');
  });

  // Sprint 4 Feature 4.3: isRichTextContentEmpty の検証。
  test('isRichTextContentEmpty は空文字/空白/不正 JSON で true', () {
    expect(isRichTextContentEmpty(''), isTrue);
    expect(isRichTextContentEmpty('   '), isTrue);
    expect(isRichTextContentEmpty('not-json'), isTrue);
    expect(isRichTextContentEmpty('[]'), isTrue);
  });

  test('isRichTextContentEmpty は改行のみの Delta で true', () {
    expect(isRichTextContentEmpty('[{"insert":"\\n"}]'), isTrue);
    expect(isRichTextContentEmpty('[{"insert":"   \\n"}]'), isTrue);
  });

  test('isRichTextContentEmpty はテキスト入り Delta で false', () {
    expect(isRichTextContentEmpty('[{"insert":"hello\\n"}]'), isFalse);
    // 末尾改行を含む短い文字列
    expect(isRichTextContentEmpty('[{"insert":"a\\n"}]'), isFalse);
  });
}
