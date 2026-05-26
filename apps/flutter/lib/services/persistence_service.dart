import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../models/history_entry.dart';
import '../models/note_group.dart';
import '../models/sticky_note.dart';

/// ノートとグループの永続化を担当する。
class PersistenceService {
  PersistenceService({Directory? baseOverride}) : _baseOverride = baseOverride;

  final Directory? _baseOverride;

  Future<Directory> _baseDir() async {
    final directory =
        _baseOverride ??
        Directory('${(await getApplicationSupportDirectory()).path}/Flote');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _atomicWriteJson(File dest, Object jsonSerializable) async {
    final encoder = const JsonEncoder.withIndent('  ');
    final tmp = File('${dest.path}.tmp');
    final bak = File('${dest.path}.bak');

    await dest.parent.create(recursive: true);
    if (await tmp.exists()) {
      await tmp.delete();
    }

    await tmp.writeAsString('${encoder.convert(jsonSerializable)}\n');

    if (await dest.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      await dest.copy(bak.path);
    }

    await tmp.rename(dest.path);
  }

  Future<List<T>> _readJsonList<T>(
    File src,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    if (!await src.exists()) {
      return const [];
    }

    try {
      return await _decodeJsonList(src, fromJson);
    } catch (error) {
      stderr.writeln('Warning: failed to read ${src.path}: $error');

      final bak = File('${src.path}.bak');
      if (!await bak.exists()) {
        return const [];
      }

      try {
        return await _decodeJsonList(bak, fromJson);
      } catch (bakError) {
        stderr.writeln('Warning: failed to read backup ${bak.path}: $bakError');
        return const [];
      }
    }
  }

  Future<List<T>> _decodeJsonList<T>(
    File src,
    T Function(Map<String, dynamic>) fromJson,
  ) async {
    final decoded = jsonDecode(await src.readAsString());
    if (decoded is! List) {
      throw const FormatException('JSON root is not a list');
    }

    final result = <T>[];
    for (var index = 0; index < decoded.length; index++) {
      final item = decoded[index];
      try {
        if (item is Map<String, dynamic>) {
          result.add(fromJson(item));
          continue;
        }
        if (item is Map) {
          result.add(fromJson(Map<String, dynamic>.from(item)));
          continue;
        }
        throw const FormatException('List item is not an object');
      } catch (error) {
        stderr.writeln(
          'Warning: skipped invalid item at ${src.path}[$index]: $error',
        );
      }
    }
    return result;
  }

  Future<void> saveNotes(List<StickyNote> notes) async {
    final dir = await _baseDir();
    final file = File('${dir.path}/notes.json');
    await _atomicWriteJson(
      file,
      notes.map((note) => note.toJson()).toList(growable: false),
    );
  }

  Future<List<StickyNote>> loadNotes() async {
    final dir = await _baseDir();
    final file = File('${dir.path}/notes.json');
    return _readJsonList(file, StickyNote.fromJson);
  }

  Future<void> saveGroups(List<NoteGroup> groups) async {
    final dir = await _baseDir();
    final file = File('${dir.path}/groups.json');
    await _atomicWriteJson(
      file,
      groups.map((group) => group.toJson()).toList(growable: false),
    );
  }

  Future<List<NoteGroup>> loadGroups() async {
    final dir = await _baseDir();
    final file = File('${dir.path}/groups.json');
    return _readJsonList(file, NoteGroup.fromJson);
  }

  /// Sprint 5 Feature 5.5: 履歴エントリを保存する。
  Future<void> saveHistory(List<HistoryEntry> entries) async {
    final dir = await _baseDir();
    final file = File('${dir.path}/history.json');
    await _atomicWriteJson(
      file,
      entries.map((entry) => entry.toJson()).toList(growable: false),
    );
  }

  /// Sprint 5 Feature 5.5: 履歴エントリを読み込む。存在しない/破損時は空。
  Future<List<HistoryEntry>> loadHistory() async {
    final dir = await _baseDir();
    final file = File('${dir.path}/history.json');
    return _readJsonList(file, HistoryEntry.fromJson);
  }

  /// Sprint 5 Feature 5.4: アプリ設定を保存する。
  Future<void> saveSettings(AppSettings settings) async {
    final dir = await _baseDir();
    final file = File('${dir.path}/settings.json');
    final encoder = const JsonEncoder.withIndent('  ');
    final tmp = File('${file.path}.tmp');
    final bak = File('${file.path}.bak');
    await file.parent.create(recursive: true);
    if (await tmp.exists()) {
      await tmp.delete();
    }
    await tmp.writeAsString('${encoder.convert(settings.toJson())}\n');
    if (await file.exists()) {
      if (await bak.exists()) {
        await bak.delete();
      }
      await file.copy(bak.path);
    }
    await tmp.rename(file.path);
  }

  /// Sprint 5 Feature 5.4: アプリ設定を読み込む。
  /// 存在しない/破損時は defaults を返す。
  Future<AppSettings> loadSettings() async {
    final dir = await _baseDir();
    final file = File('${dir.path}/settings.json');
    if (!await file.exists()) {
      return AppSettings.defaults();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return AppSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
      return AppSettings.defaults();
    } catch (error) {
      stderr.writeln('Warning: failed to read settings.json: $error');
      final bak = File('${file.path}.bak');
      if (!await bak.exists()) {
        return AppSettings.defaults();
      }
      try {
        final decoded = jsonDecode(await bak.readAsString());
        if (decoded is Map<String, dynamic>) {
          return AppSettings.fromJson(decoded);
        }
        if (decoded is Map) {
          return AppSettings.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (bakError) {
        stderr.writeln('Warning: failed to read settings.json.bak: $bakError');
      }
      return AppSettings.defaults();
    }
  }
}
