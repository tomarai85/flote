const Object _undefined = Object();

DateTime _readDateTime(Object? value, DateTime fallback) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return fallback;
}

/// ノートグループ。
class NoteGroup {
  NoteGroup({
    required this.id,
    required this.name,
    required this.parentGroupID,
    required this.iconName,
    required this.colorHex,
    required this.createdAt,
  });

  final String id;
  final String name;
  final String? parentGroupID;
  final String? iconName;
  final String? colorHex;
  final DateTime createdAt;

  /// Inbox (システムグループ) の固定 ID。
  static const String inboxId = 'group.system.inbox';

  NoteGroup copyWith({
    String? id,
    String? name,
    Object? parentGroupID = _undefined,
    Object? iconName = _undefined,
    Object? colorHex = _undefined,
    DateTime? createdAt,
  }) {
    return NoteGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      parentGroupID: identical(parentGroupID, _undefined)
          ? this.parentGroupID
          : parentGroupID as String?,
      iconName: identical(iconName, _undefined)
          ? this.iconName
          : iconName as String?,
      colorHex: identical(colorHex, _undefined)
          ? this.colorHex
          : colorHex as String?,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory NoteGroup.fromJson(Map<String, dynamic> json) {
    return NoteGroup(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Untitled',
      parentGroupID: json['parentGroupID'] as String?,
      iconName: json['iconName'] as String?,
      colorHex: json['colorHex'] as String?,
      createdAt: _readDateTime(json['createdAt'], DateTime.now()),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'parentGroupID': parentGroupID,
      'iconName': iconName,
      'colorHex': colorHex,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is NoteGroup &&
        other.id == id &&
        other.name == name &&
        other.parentGroupID == parentGroupID &&
        other.iconName == iconName &&
        other.colorHex == colorHex &&
        other.createdAt == createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(id, name, parentGroupID, iconName, colorHex, createdAt);
  }
}
