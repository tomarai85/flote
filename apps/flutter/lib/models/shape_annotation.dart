double _readDouble(Object? value, double fallback) {
  if (value is num) {
    return value.toDouble();
  }
  return fallback;
}

ShapeType _parseShapeType(String name) {
  for (final type in ShapeType.values) {
    if (type.name == name) {
      return type;
    }
  }
  return ShapeType.rectangle;
}

enum ShapeType {
  arrow,
  rectangle,
  circle,
  underline,
  doubleUnderline,
  wavyUnderline,
}

class ShapeAnnotation {
  ShapeAnnotation({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.r,
    required this.g,
    required this.b,
    required this.a,
    required this.lineWidth,
  });

  final String id;
  final ShapeType type;
  final double x;
  final double y;
  final double width;
  final double height;
  final double r;
  final double g;
  final double b;
  final double a;
  final double lineWidth;

  ShapeAnnotation copyWith({
    String? id,
    ShapeType? type,
    double? x,
    double? y,
    double? width,
    double? height,
    double? r,
    double? g,
    double? b,
    double? a,
    double? lineWidth,
  }) {
    return ShapeAnnotation(
      id: id ?? this.id,
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      r: r ?? this.r,
      g: g ?? this.g,
      b: b ?? this.b,
      a: a ?? this.a,
      lineWidth: lineWidth ?? this.lineWidth,
    );
  }

  factory ShapeAnnotation.fromJson(Map<String, dynamic> json) {
    return ShapeAnnotation(
      id: json['id'] as String? ?? '',
      type: _parseShapeType(json['type'] as String? ?? ''),
      x: _readDouble(json['x'], 0),
      y: _readDouble(json['y'], 0),
      width: _readDouble(json['width'], 0),
      height: _readDouble(json['height'], 0),
      r: _readDouble(json['r'], 0),
      g: _readDouble(json['g'], 0),
      b: _readDouble(json['b'], 0),
      a: _readDouble(json['a'], 1),
      lineWidth: _readDouble(json['lineWidth'], 1),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'r': r,
      'g': g,
      'b': b,
      'a': a,
      'lineWidth': lineWidth,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ShapeAnnotation &&
        other.id == id &&
        other.type == type &&
        other.x == x &&
        other.y == y &&
        other.width == width &&
        other.height == height &&
        other.r == r &&
        other.g == g &&
        other.b == b &&
        other.a == a &&
        other.lineWidth == lineWidth;
  }

  @override
  int get hashCode {
    return Object.hash(id, type, x, y, width, height, r, g, b, a, lineWidth);
  }
}
