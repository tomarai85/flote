import 'package:flutter_test/flutter_test.dart';

import 'package:flote_desktop/models/shape_annotation.dart';

void main() {
  group('ShapeAnnotation', () {
    test('encode/decode round-trip for each ShapeType', () {
      for (final type in ShapeType.values) {
        final annotation = ShapeAnnotation(
          id: 'shape-${type.name}',
          type: type,
          x: 1,
          y: 2,
          width: 3,
          height: 4,
          r: 0.1,
          g: 0.2,
          b: 0.3,
          a: 0.4,
          lineWidth: 2,
        );

        final decoded = ShapeAnnotation.fromJson(annotation.toJson());

        expect(decoded, equals(annotation));
      }
    });

    test('invalid type falls back to rectangle', () {
      final annotation = ShapeAnnotation.fromJson({
        'id': 'shape-1',
        'type': 'unknown',
      });

      expect(annotation.type, ShapeType.rectangle);
    });
  });
}
