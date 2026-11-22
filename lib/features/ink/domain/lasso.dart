/// Kement seçimi ve seçimin taşınması, ölçeklenmesi, döndürülmesi (saf Dart).
library;

import 'dart:math' as math;

import 'ink_models.dart';
import 'ink_object.dart';

/// Işın atma ile nokta çokgenin içinde mi (çokgen otomatik kapanır).
bool pointInPolygon(List<InkPoint> poly, double x, double y) {
  if (poly.length < 3) return false;
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.y > y) != (b.y > y) &&
        x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

/// Çizginin noktalarının en az [ratio] oranı kementin içindeyse seçilir.
bool strokeInLasso(InkObject s, List<InkPoint> lasso, {double ratio = 0.5}) {
  if (s.points.isEmpty || lasso.length < 3) return false;
  var inside = 0;
  for (final p in s.points) {
    if (pointInPolygon(lasso, p.x, p.y)) inside++;
  }
  return inside / s.points.length >= ratio && inside > 0;
}

List<InkObject> selectByLasso(
  Iterable<InkObject> strokes,
  List<InkPoint> lasso, {
  double ratio = 0.5,
}) => [
  for (final s in strokes)
    if (strokeInLasso(s, lasso, ratio: ratio)) s,
];

/// Çizgilerin sınır kutusu (kalınlık dahil); boşsa null.
InkRect? selectionBounds(Iterable<InkObject> strokes) {
  InkRect? r;
  for (final s in strokes) {
    final h = s.halfWidth;
    for (final p in s.points) {
      final b = InkRect(p.x - h, p.y - h, p.x + h, p.y + h);
      r = r == null ? b : r.union(b);
    }
  }
  return r;
}

InkPoint _map(InkPoint p, double x, double y) => InkPoint(
  x: x,
  y: y,
  pressure: p.pressure,
  tilt: p.tilt,
  tMs: p.tMs,
);

InkObject translateObject(InkObject s, double dx, double dy) => s.copyWith(
  points: [for (final p in s.points) _map(p, p.x + dx, p.y + dy)],
);

/// [cx],[cy] merkezli ölçekleme. [scaleWidth] true ise kalınlık
/// `sqrt(|sx*sy|)` ile orantılanır, false ise korunur.
InkObject scaleObject(
  InkObject s,
  double sx,
  double sy,
  double cx,
  double cy, {
  bool scaleWidth = false,
}) {
  final pts = [
    for (final p in s.points)
      _map(p, cx + (p.x - cx) * sx, cy + (p.y - cy) * sy),
  ];
  final w = scaleWidth
      ? s.brush.width * math.sqrt((sx * sy).abs())
      : s.brush.width;
  return s.copyWith(points: pts, brush: s.brush.copyWith(width: w));
}

/// [cx],[cy] çevresinde [radians] kadar döndürme (kalınlık değişmez).
InkObject rotateObject(InkObject s, double radians, double cx, double cy) {
  final c = math.cos(radians), sn = math.sin(radians);
  return s.copyWith(
    points: [
      for (final p in s.points)
        _map(
          p,
          cx + (p.x - cx) * c - (p.y - cy) * sn,
          cy + (p.x - cx) * sn + (p.y - cy) * c,
        ),
    ],
  );
}

/// Seçimi bir kutudan diğerine uyduran ölçek (köşe tutamacı sürükleme).
/// [keepAspect] true ise küçük ölçek iki eksene de uygulanır.
List<InkObject> resizeSelection(
  List<InkObject> strokes,
  InkRect from,
  InkRect to, {
  bool keepAspect = false,
  bool scaleWidth = false,
}) {
  final sx0 = from.width == 0 ? 1.0 : to.width / from.width;
  final sy0 = from.height == 0 ? 1.0 : to.height / from.height;
  var sx = sx0, sy = sy0;
  if (keepAspect) {
    final k = sx0.abs() < sy0.abs() ? sx0 : sy0;
    sx = k;
    sy = k;
  }
  return [
    for (final s in strokes)
      translateObject(
        scaleObject(s, sx, sy, from.left, from.top, scaleWidth: scaleWidth),
        to.left - from.left,
        to.top - from.top,
      ),
  ];
}
