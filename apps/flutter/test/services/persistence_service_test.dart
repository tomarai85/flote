import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/note_color_theme.dart';
import 'package:flote_desktop/models/note_group.dart';
import 'package:flote_desktop/models/sticky_note.dart';
import 'package:flote_desktop/models/stow_state.dart';
import 'package:flote_desktop/services/persistence_service.dart';

void main() {
  group('PersistenceService', () {
    late Directory tempDir;
    late PersistenceService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('flote_test_');
      service = PersistenceService(baseOverride: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('saveNotes then loadNotes round-trips', () async {
      final notes = [
        StickyNote(
          id: 'note-1',
          text: 'Hello',
          richText: '{"ops":[]}',
          positionX: 10,
          positionY: 20,
          width: 160,
          height: 120,
          colorTheme: NoteColorTheme.green,
          createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
          modifiedAt: DateTime.parse('2026-04-19T11:00:00.000Z'),
          zOrder: 2,
          stowState: StowState.mini,
          rolledTitle: 'Mini',
          groupID: 'group-1',
          isPanelOpen: true,
          sortedAt: DateTime.parse('2026-04-19T12:00:00.000Z'),
          shapes: const [],
        ),
      ];

      await service.saveNotes(notes);

      final loaded = await service.loadNotes();

      expect(loaded, equals(notes));
    });

    test('loadNotes returns empty list when file missing', () async {
      final loaded = await service.loadNotes();

      expect(loaded, isEmpty);
    });

    test('corrupted JSON falls back to bak', () async {
      final note = StickyNote(
        id: 'note-1',
        text: 'Recovered',
        richText: '',
        positionX: 0,
        positionY: 0,
        width: 160,
        height: 120,
        colorTheme: NoteColorTheme.yellow,
        createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
        modifiedAt: DateTime.parse('2026-04-19T11:00:00.000Z'),
        zOrder: 0,
        stowState: StowState.expanded,
        rolledTitle: '',
        groupID: null,
        isPanelOpen: true,
        sortedAt: null,
        shapes: const [],
      );
      final notesFile = File('${tempDir.path}/notes.json');
      final backupFile = File('${tempDir.path}/notes.json.bak');

      await notesFile.writeAsString('{invalid json');
      await backupFile.writeAsString(jsonEncode([note.toJson()]));

      final loaded = await service.loadNotes();

      expect(loaded, [note]);
    });

    test('saveGroups then loadGroups round-trips', () async {
      final groups = [
        NoteGroup(
          id: 'group-1',
          name: 'Inbox',
          parentGroupID: null,
          iconName: 'tray',
          colorHex: '#FFD700',
          createdAt: DateTime.parse('2026-04-19T10:00:00.000Z'),
        ),
      ];

      await service.saveGroups(groups);

      final loaded = await service.loadGroups();

      expect(loaded, equals(groups));
    });
  });
}
