import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 相対輝度 (WCAG 2.0 Relative Luminance) を返す (0..1)。
double relativeLuminance(Color color) {
  final red = _linearizeChannel(color.r);
  final green = _linearizeChannel(color.g);
  final blue = _linearizeChannel(color.b);
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
}

/// foreground と background のコントラスト比 (1..21)。
double contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = relativeLuminance(foreground);
  final backgroundLuminance = relativeLuminance(background);
  final lighter = foregroundLuminance >= backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance < backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

/// WCAG AA (4.5:1) を満たすか。
bool meetsWcagAA(Color foreground, Color background) {
  return contrastRatio(foreground, background) >= 4.5;
}

/// 指定背景に対して WCAG AA を満たす foreground 候補のうち、最もコントラストが高いものを返す。
/// 候補リストを渡して最良を選ぶヘルパー。
Color bestForegroundFor(
  Color background, {
  List<Color> candidates = const [Color(0xFF1C1C1E), Color(0xFFFFFFFF)],
}) {
  if (candidates.isEmpty) {
    return const Color(0xFF1C1C1E);
  }

  final ranked = [...candidates]
    ..sort(
      (left, right) => contrastRatio(
        right,
        background,
      ).compareTo(contrastRatio(left, background)),
    );

  for (final candidate in ranked) {
    if (meetsWcagAA(candidate, background)) {
      return candidate;
    }
  }

  return ranked.first;
}

double _linearizeChannel(double channel) {
  if (channel <= 0.03928) {
    return channel / 12.92;
  }
  return math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
}
