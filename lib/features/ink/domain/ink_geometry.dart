/// Silgi için saf geometri.
library;

import 'dart:math' as math;

import 'ink_models.dart';

/// (x, y) noktası çizgiye [radius] içinde mi? Çizginin kendi yarı kalınlığı
/// [halfWidth] da sayılır.
bool strokeHitsPoint(
  List<InkPoint> pts,
  double x,
  double y,
  double radius, {
  double halfWidth = 0,
}) {
  if (pts.isEmpty) return false;
  final r = radius + halfWidth;
  if (pts.length == 1) return _dist(pts[0].x, pts[0].y, x, y) <= r;
  for (var i = 0; i < pts.length - 1; i++) {
    if (_segDist(pts[i], pts[i + 1], x, y) <= r) return true;
  }
  return false;
}

double _dist(double ax, double ay, double bx, double by) =>
    math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by));

double _segDist(InkPoint a, InkPoint b, double px, double py) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  if (len2 == 0) return _dist(a.x, a.y, px, py);
  final t = (((px - a.x) * dx + (py - a.y) * dy) / len2).clamp(0.0, 1.0);
  return _dist(a.x + t * dx, a.y + t * dy, px, py);
}
