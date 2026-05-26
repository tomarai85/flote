// 削除されたノートの履歴エントリ (Sprint 5 Feature 5.5)。
//
// ユーザーがノートを削除すると、notes.json から除外される代わりに history.json
// へ追加される。Settings > History から一覧表示・復元・永久削除が可能。
// 最大 100 件まで保存し、それ以上は deletedAt が古いものから自動的に pruning。

import 'note_color_theme.dart';

/// 履歴エントリ。ノート復元に必要な最小限の情報を保持する。
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.deletedAt,
    required this.text,
    required this.richText,
    required this.colorTheme,
    required this.originalGroupID,
  });

  /// 元のノート ID。復元時は新規 ID を振り直すため、この値は参考情報のみ。
  final String id;

  /// 削除された日時 (相対表示の元にする)。
  final DateTime deletedAt;

  /// 削除時のプレーンテキスト (履歴一覧プレビュー用)。
  final String text;

  /// 削除時の rich text Delta JSON。復元時に新ノートへ移植。
  final String richText;

  /// 削除時のノートカラーテーマ。復元時に再使用。
  final NoteColorTheme colorTheme;

  /// 削除時に所属していたグループ ID (参考情報)。復元時は Inbox 強制割当なので使わない。
  final String? originalGroupID;

  HistoryEntry copyWith({
    String? id,
    DateTime? deletedAt,
    String? text,
    String? richText,
    NoteColorTheme? colorTheme,
    String? originalGroupID,
  }) {
    return HistoryEntry(
      id: id ?? this.id,
      deletedAt: deletedAt ?? this.deletedAt,
      text: text ?? this.text,
      richText: richText ?? this.richText,
      colorTheme: colorTheme ?? this.colorTheme,
      originalGroupID: originalGroupID ?? this.originalGroupID,
    );
  }

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    final deleted = json['deletedAt'];
    DateTime deletedAt = DateTime.now();
    if (deleted is String) {
      final parsed = DateTime.tryParse(deleted);
      if (parsed != null) {
        deletedAt = parsed;
      }
    }
    return HistoryEntry(
      id: json['id'] as String? ?? '',
      deletedAt: deletedAt,
      text: json['text'] as String? ?? '',
      richText: json['richText'] as String? ?? '',
      colorTheme: parseNoteColorTheme(json['colorTheme'] as String? ?? ''),
      originalGroupID: json['originalGroupID'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deletedAt': deletedAt.toIso8601String(),
      'text': text,
      'richText': richText,
      'colorTheme': colorTheme.name,
      'originalGroupID': originalGroupID,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is HistoryEntry &&
        other.id == id &&
        other.deletedAt == deletedAt &&
        other.text == text &&
        other.richText == richText &&
        other.colorTheme == colorTheme &&
        other.originalGroupID == originalGroupID;
  }

  @override
  int get hashCode => Object.hash(
        id,
        deletedAt,
        text,
        richText,
        colorTheme,
        originalGroupID,
      );
}
