/// Çizgi silgisi ve alan silgisi (saf Dart).
library;

import 'dart:math' as math;

import 'ink_models.dart';
import 'ink_object.dart';

double _segDist(double ax, double ay, double bx, double by, double px, double py) {
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  var t = 0.0;
  if (len2 > 0) {
    t = (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0);
  }
  final qx = ax + t * dx - px, qy = ay + t * dy - py;
  return math.sqrt(qx * qx + qy * qy);
}

/// Nokta, [path] (tek nokta ya da kırık çizgi) üzerindeki en yakın noktaya uzaklık.
double distanceToPath(List<InkPoint> path, double x, double y) {
  if (path.isEmpty) return double.infinity;
  if (path.length == 1) {
    final dx = path[0].x - x, dy = path[0].y - y;
    return math.sqrt(dx * dx + dy * dy);
  }
  var best = double.infinity;
  for (var i = 0; i < path.length - 1; i++) {
    final d = _segDist(path[i].x, path[i].y, path[i + 1].x, path[i + 1].y, x, y);
    if (d < best) best = d;
  }
  return best;
}

/// Çizgi silgisi: silgi yolu ([radius] yarıçaplı) çizgiye (kalınlık dahil)
/// değiyorsa çizgi döner.
List<InkObject> strokesTouchedByEraser(
  Iterable<InkObject> strokes,
  List<InkPoint> eraserPath,
  double radius,
) {
  final out = <InkObject>[];
  if (eraserPath.isEmpty) return out;
  for (final s in strokes) {
    if (_touches(s, eraserPath, radius)) out.add(s);
  }
  return out;
}

bool _touches(InkObject s, List<InkPoint> path, double radius) {
  final pts = s.points;
  if (pts.isEmpty) return false;
  final r = radius + s.halfWidth;
  if (pts.length == 1) return distanceToPath(path, pts[0].x, pts[0].y) <= r;
  // Çizgi parçası - silgi yolu uzaklığı: silgi örnekleri çizgi parçasına,
  // çizgi uçları silgi yoluna bakılır (kesişen parçalar için ayrıca kontrol).
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    if (path.length == 1) {
      if (_segDist(a.x, a.y, b.x, b.y, path[0].x, path[0].y) <= r) return true;
      continue;
    }
    for (var j = 0; j < path.length - 1; j++) {
      if (_segSegDist(a, b, path[j], path[j + 1]) <= r) return true;
    }
  }
  return false;
}

double _segSegDist(InkPoint a, InkPoint b, InkPoint c, InkPoint d) {
  if (_intersect(a, b, c, d)) return 0;
  return math.min(
    math.min(_segDist(a.x, a.y, b.x, b.y, c.x, c.y),
        _segDist(a.x, a.y, b.x, b.y, d.x, d.y)),
    math.min(_segDist(c.x, c.y, d.x, d.y, a.x, a.y),
        _segDist(c.x, c.y, d.x, d.y, b.x, b.y)),
  );
}

double _cross(InkPoint o, InkPoint a, InkPoint b) =>
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);

bool _intersect(InkPoint a, InkPoint b, InkPoint c, InkPoint d) {
  final d1 = _cross(c, d, a), d2 = _cross(c, d, b);
  final d3 = _cross(a, b, c), d4 = _cross(a, b, d);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

InkPoint _lerp(InkPoint a, InkPoint b, double t) => InkPoint(
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  pressure: a.pressure + (b.pressure - a.pressure) * t,
  tilt: a.tilt + (b.tilt - a.tilt) * t,
  tMs: a.tMs + (b.tMs - a.tMs) * t,
);

/// Alan silgisi sonucu.
class EraseResult {
  const EraseResult(this.pieces, this.changed);

  /// Geriye kalan parçalar (her biri en az 2 nokta); silgi hiç değmediyse
  /// özgün çizgi tek parça olarak aynen döner.
  final List<InkObject> pieces;

  /// Silgi çizgiye değdi mi.
  final bool changed;
}

/// Alan silgisi: çizgiyi silgi yolu boyunca böler. Parçalar özgün çizgiden
/// `id#0`, `id#1` ... kimliği alır; fırça (kalınlık), baskı ve zaman korunur.
/// Silgi yolu üstündeki kısım atılır.
EraseResult eraseArea(
  InkObject stroke,
  List<InkPoint> eraserPath,
  double radius, {
  String Function(String baseId, int index)? idFor,
}) {
  final pts = stroke.points;
  if (pts.isEmpty || eraserPath.isEmpty || !_touches(stroke, eraserPath, radius)) {
    return EraseResult([stroke], false);
  }
  final r = radius + stroke.halfWidth;
  // Seyrek örneklenmiş çizgide silgi arada kalmasın: parçaları sıklaştır.
  final step = math.max(r / 3, 0.25);
  final dense = <InkPoint>[pts.first];
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final dx = b.x - a.x, dy = b.y - a.y;
    final len = math.sqrt(dx * dx + dy * dy);
    final n = (len / step).ceil();
    for (var k = 1; k < n; k++) {
      dense.add(_lerp(a, b, k / n));
    }
    dense.add(b);
  }
  final pieces = <List<InkPoint>>[];
  var cur = <InkPoint>[];
  for (final p in dense) {
    if (distanceToPath(eraserPath, p.x, p.y) <= r) {
      if (cur.length >= 2) pieces.add(cur);
      cur = <InkPoint>[];
    } else {
      cur.add(p);
    }
  }
  if (cur.length >= 2) pieces.add(cur);
  String name(int i) => idFor != null ? idFor(stroke.id, i) : '${stroke.id}#$i';
  return EraseResult([
    for (var i = 0; i < pieces.length; i++)
      stroke.copyWith(id: name(i), points: pieces[i]),
  ], true);
}
