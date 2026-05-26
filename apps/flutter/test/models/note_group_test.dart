import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/note_group.dart';

void main() {
  group('NoteGroup', () {
    test('encode/decode round-trip', () {
      final group = NoteGroup(
        id: 'group-1',
        name: 'Projects',
        parentGroupID: 'parent-1',
        iconName: 'folder',
        colorHex: '#AABBCC',
        createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
      );

      final decoded = NoteGroup.fromJson(group.toJson());

      expect(decoded, equals(group));
    });

    test('inboxId constant is stable', () {
      expect(NoteGroup.inboxId, 'group.system.inbox');
    });

    test('missing name falls back to Untitled', () {
      final group = NoteGroup.fromJson({'id': 'group-1'});

      expect(group.name, 'Untitled');
    });
  });
}
