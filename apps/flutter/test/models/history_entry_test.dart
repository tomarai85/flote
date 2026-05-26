// Sprint 5: HistoryEntry の round-trip テスト。

import 'package:flote_desktop/models/history_entry.dart';
import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HistoryEntry', () {
    test('toJson / fromJson で round-trip する', () {
      final e = HistoryEntry(
        id: 'note-1',
        deletedAt: DateTime.parse('2026-04-19T10:30:00.000Z'),
        text: 'hello',
        richText: '[{"insert":"hello\\n"}]',
        colorTheme: NoteColorTheme.blue,
        originalGroupID: 'group.system.inbox',
      );
      final restored = HistoryEntry.fromJson(e.toJson());
      expect(restored, equals(e));
    });

    test('fromJson で deletedAt が不正な場合は現在時刻にフォールバック', () {
      final restored = HistoryEntry.fromJson(const {
        'id': 'x',
        'deletedAt': 'not-a-date',
        'text': 't',
        'richText': '',
        'colorTheme': 'yellow',
      });
      // 1 分以内で差分が収まることを確認 (fallback は DateTime.now)。
      expect(
        DateTime.now().difference(restored.deletedAt).inMinutes.abs(),
        lessThan(1),
      );
    });

    test('fromJson で不明な colorTheme は yellow にフォールバック', () {
      final restored = HistoryEntry.fromJson(const {
        'id': 'x',
        'deletedAt': '2026-04-19T10:00:00.000Z',
        'text': 't',
        'richText': '',
        'colorTheme': '???',
      });
      expect(restored.colorTheme, NoteColorTheme.yellow);
    });

    test('copyWith は指定フィールドのみ差替える', () {
      final e = HistoryEntry(
        id: 'a',
        deletedAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
        text: 'a',
        richText: '',
        colorTheme: NoteColorTheme.yellow,
        originalGroupID: null,
      );
      final updated = e.copyWith(text: 'b');
      expect(updated.text, 'b');
      expect(updated.id, 'a');
    });
  });
}
