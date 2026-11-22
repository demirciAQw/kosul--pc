import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

import '../domain/ink_models.dart';

/// Noktalardan dolu çizgi yolunu üretir (perfect_freehand, MIT).
/// [pressureFromDevice] false ise (fare) baskı benzetilir.
Path inkOutlinePath(
  List<InkPoint> points,
  InkBrush brush, {
  required bool complete,
  bool pressureFromDevice = true,
}) {
  if (points.isEmpty) return Path();
  final highlighter = brush.tool == InkTool.highlighter;
  final options = StrokeOptions(
    size: brush.width,
    thinning: highlighter ? 0 : 0.55,
    smoothing: 0.5,
    streamline: 0.4,
    simulatePressure: !pressureFromDevice && !highlighter,
    isComplete: complete,
  );
  final outline = getStroke([
    for (final p in points)
      PointVector(p.x, p.y, pressureFromDevice ? p.pressure : null),
  ], options: options);
  final path = Path();
  if (outline.length < 2) return path;
  path.moveTo(outline[0].dx, outline[0].dy);
  for (var i = 0; i < outline.length - 1; i++) {
    final a = outline[i], b = outline[i + 1];
    path.quadraticBezierTo(a.dx, a.dy, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  }
  path.close();
  return path;
}

/// Fırça boyası: fosforlu yarı saydam.
Paint inkPaintFor(InkBrush brush) {
  final base = Color(brush.color);
  final color = brush.tool == InkTool.highlighter
      ? base.withValues(alpha: base.a * 0.35)
      : base;
  return Paint()
    ..color = color
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
}
