import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/shape_annotation.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';

void main() {
  group('StickyNote', () {
    test('encode/decode round-trip preserves all fields', () {
      final note = StickyNote(
        id: 'note-1',
        text: 'Hello',
        richText: '{"ops":[]}',
        positionX: 12.5,
        positionY: 34.5,
        width: 220,
        height: 180,
        colorTheme: NoteColorTheme.blue,
        createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
        modifiedAt: DateTime.parse('2026-04-19T11:00:00.000Z'),
        zOrder: 7,
        stowState: StowState.rolledUp,
        rolledTitle: 'Pinned',
        groupID: 'group-1',
        isPanelOpen: false,
        sortedAt: DateTime.parse('2026-04-19T12:00:00.000Z'),
        shapes: [
          ShapeAnnotation(
            id: 'shape-1',
            type: ShapeType.arrow,
            x: 1,
            y: 2,
            width: 3,
            height: 4,
            r: 0.1,
            g: 0.2,
            b: 0.3,
            a: 0.4,
            lineWidth: 2,
          ),
        ],
      );

      final decoded = StickyNote.fromJson(note.toJson());

      expect(decoded, equals(note));
    });

    test('missing optional fields fall back to defaults', () {
      final note = StickyNote.fromJson({'id': 'note-1', 'text': 'Hello'});

      expect(note.id, 'note-1');
      expect(note.text, 'Hello');
      expect(note.richText, '');
      expect(note.width, 160);
      expect(note.height, 120);
      expect(note.zOrder, 0);
      expect(note.isPanelOpen, isTrue);
      expect(note.groupID, isNull);
      expect(note.sortedAt, isNull);
      expect(note.shapes, isEmpty);
    });

    test('invalid enum falls back', () {
      final note = StickyNote.fromJson({
        'id': 'note-1',
        'text': 'Hello',
        'colorTheme': 'unknown',
        'stowState': 'unknown',
      });

      expect(note.colorTheme, NoteColorTheme.yellow);
      expect(note.stowState, StowState.expanded);
    });

    test('copyWith overrides only specified fields', () {
      final original = StickyNote(
        id: 'note-1',
        text: 'old',
        richText: 'rich',
        positionX: 10,
        positionY: 20,
        width: 160,
        height: 120,
        colorTheme: NoteColorTheme.yellow,
        createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
        modifiedAt: DateTime.parse('2026-04-19T11:00:00.000Z'),
        zOrder: 1,
        stowState: StowState.expanded,
        rolledTitle: '',
        groupID: null,
        isPanelOpen: true,
        sortedAt: null,
        shapes: const [],
      );

      final updated = original.copyWith(text: 'new');

      expect(updated.text, 'new');
      expect(updated.id, original.id);
      expect(updated.richText, original.richText);
      expect(updated.positionX, original.positionX);
      expect(updated.positionY, original.positionY);
      expect(updated.width, original.width);
      expect(updated.height, original.height);
      expect(updated.colorTheme, original.colorTheme);
      expect(updated.createdAt, original.createdAt);
      expect(updated.modifiedAt, original.modifiedAt);
      expect(updated.zOrder, original.zOrder);
      expect(updated.stowState, original.stowState);
      expect(updated.rolledTitle, original.rolledTitle);
      expect(updated.groupID, original.groupID);
      expect(updated.isPanelOpen, original.isPanelOpen);
      expect(updated.sortedAt, original.sortedAt);
      expect(updated.shapes, original.shapes);
    });
  });
}
