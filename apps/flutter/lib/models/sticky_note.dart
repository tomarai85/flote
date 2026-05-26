import 'note_color_theme.dart';
import 'shape_annotation.dart';
import 'stow_state.dart';

const Object _undefined = Object();

double _readDouble(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }
  return fallback;
}

int _readInt(Object? value, int fallback) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return fallback;
}

bool _readBool(Object? value, bool fallback) {
  if (value is bool) {
    return value;
  }
  return fallback;
}

DateTime _readDateTime(Object? value, DateTime fallback) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return fallback;
}

DateTime? _readNullableDateTime(Object? value) {
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}

bool _shapeListEquals(List<ShapeAnnotation> left, List<ShapeAnnotation> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

/// 付箋ノート。
class StickyNote {
  StickyNote({
    required this.id,
    required this.text,
    required this.richText,
    required this.positionX,
    required this.positionY,
    required this.width,
    required this.height,
    required this.colorTheme,
    required this.createdAt,
    required this.modifiedAt,
    required this.zOrder,
    required this.stowState,
    required this.rolledTitle,
    required this.groupID,
    required this.isPanelOpen,
    required this.sortedAt,
    required List<ShapeAnnotation> shapes,
  }) : shapes = List<ShapeAnnotation>.unmodifiable(shapes);

  final String id;
  final String text;
  final String richText;
  final double positionX;
  final double positionY;
  final double width;
  final double height;
  final NoteColorTheme colorTheme;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final int zOrder;
  final StowState stowState;
  final String rolledTitle;
  final String? groupID;
  final bool isPanelOpen;
  final DateTime? sortedAt;
  final List<ShapeAnnotation> shapes;

  StickyNote copyWith({
    String? id,
    String? text,
    String? richText,
    double? positionX,
    double? positionY,
    double? width,
    double? height,
    NoteColorTheme? colorTheme,
    DateTime? createdAt,
    DateTime? modifiedAt,
    int? zOrder,
    StowState? stowState,
    String? rolledTitle,
    Object? groupID = _undefined,
    bool? isPanelOpen,
    Object? sortedAt = _undefined,
    List<ShapeAnnotation>? shapes,
  }) {
    return StickyNote(
      id: id ?? this.id,
      text: text ?? this.text,
      richText: richText ?? this.richText,
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      width: width ?? this.width,
      height: height ?? this.height,
      colorTheme: colorTheme ?? this.colorTheme,
      createdAt: createdAt ?? this.createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      zOrder: zOrder ?? this.zOrder,
      stowState: stowState ?? this.stowState,
      rolledTitle: rolledTitle ?? this.rolledTitle,
      groupID: identical(groupID, _undefined)
          ? this.groupID
          : groupID as String?,
      isPanelOpen: isPanelOpen ?? this.isPanelOpen,
      sortedAt: identical(sortedAt, _undefined)
          ? this.sortedAt
          : sortedAt as DateTime?,
      shapes: shapes ?? this.shapes,
    );
  }

  factory StickyNote.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    final rawShapes = json['shapes'];
    final shapes = <ShapeAnnotation>[];
    if (rawShapes is List) {
      for (final item in rawShapes) {
        if (item is Map<String, dynamic>) {
          shapes.add(ShapeAnnotation.fromJson(item));
          continue;
        }
        if (item is Map) {
          shapes.add(ShapeAnnotation.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    return StickyNote(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      richText: json['richText'] as String? ?? '',
      positionX: _readDouble(json['positionX'], 0),
      positionY: _readDouble(json['positionY'], 0),
      width: _readDouble(json['width'], 160),
      height: _readDouble(json['height'], 120),
      colorTheme: parseNoteColorTheme(json['colorTheme'] as String? ?? ''),
      createdAt: _readDateTime(json['createdAt'], now),
      modifiedAt: _readDateTime(json['modifiedAt'], now),
      zOrder: _readInt(json['zOrder'], 0),
      stowState: parseStowState(json['stowState'] as String? ?? ''),
      rolledTitle: json['rolledTitle'] as String? ?? '',
      groupID: json['groupID'] as String?,
      isPanelOpen: _readBool(json['isPanelOpen'], true),
      sortedAt: _readNullableDateTime(json['sortedAt']),
      shapes: List<ShapeAnnotation>.unmodifiable(shapes),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'text': text,
      'richText': richText,
      'positionX': positionX,
      'positionY': positionY,
      'width': width,
      'height': height,
      'colorTheme': colorTheme.name,
      'createdAt': createdAt.toIso8601String(),
      'modifiedAt': modifiedAt.toIso8601String(),
      'zOrder': zOrder,
      'stowState': stowState.name,
      'rolledTitle': rolledTitle,
      'groupID': groupID,
      'isPanelOpen': isPanelOpen,
      'sortedAt': sortedAt?.toIso8601String(),
      'shapes': shapes.map((shape) => shape.toJson()).toList(growable: false),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is StickyNote &&
        other.id == id &&
        other.text == text &&
        other.richText == richText &&
        other.positionX == positionX &&
        other.positionY == positionY &&
        other.width == width &&
        other.height == height &&
        other.colorTheme == colorTheme &&
        other.createdAt == createdAt &&
        other.modifiedAt == modifiedAt &&
        other.zOrder == zOrder &&
        other.stowState == stowState &&
        other.rolledTitle == rolledTitle &&
        other.groupID == groupID &&
        other.isPanelOpen == isPanelOpen &&
        other.sortedAt == sortedAt &&
        _shapeListEquals(other.shapes, shapes);
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      text,
      richText,
      positionX,
      positionY,
      width,
      height,
      colorTheme,
      createdAt,
      modifiedAt,
      zOrder,
      stowState,
      rolledTitle,
      groupID,
      isPanelOpen,
      sortedAt,
      Object.hashAll(shapes),
    );
  }
}
