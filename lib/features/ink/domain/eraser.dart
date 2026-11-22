/// Çizgi silgisi ve alan silgisi (saf Dart).
library;

import 'dart:math' as math;

import 'package:uuid/uuid.dart';

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
  _checkRadius(radius);
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

const _uuid = Uuid();

void _checkRadius(double radius) {
  if (!radius.isFinite || radius < 0) {
    throw ArgumentError.value(radius, 'radius', 'Silgi yarıçapı sonlu ve negatif olmayan bir sayı olmalı');
  }
}

/// Alan silgisi: çizgiyi silgi yolu boyunca böler. Fırça (kalınlık) korunur.
/// Parçalarda özgün köşe noktaları aynen kalır; yalnız silgi sınırına bir kesişim
/// noktası (baskı, eğim ve zaman doğrusal aradeğerlenmiş) eklenir: kesim başına
/// en çok 2 yeni nokta, art arda silmede çizgi şişmez. Silgi yolu üstündeki kısım atılır.
///
/// Parçalar YENİ kimlik alır ([idFor] verilmezse UUID v4; iki cihazda ya da
/// yeniden bölmede çakışmaz). Çağıran, `changed` ise özgün çizgiyi YUMUŞAK
/// silmeli (kayıt kalır, geri alınabilir) ve parçaları eklemelidir.
EraseResult eraseArea(
  InkObject stroke,
  List<InkPoint> eraserPath,
  double radius, {
  String Function(String baseId, int index)? idFor,
}) {
  _checkRadius(radius);
  final pts = stroke.points;
  if (pts.isEmpty || eraserPath.isEmpty || !_touches(stroke, eraserPath, radius)) {
    return EraseResult([stroke], false);
  }
  final r = radius + stroke.halfWidth;
  bool hit(InkPoint p) => distanceToPath(eraserPath, p.x, p.y) <= r;

  // Sıklaştırılmış noktalar YALNIZ "silgi değdi mi" kararı içindir; seyrek
  // çizgide silgi iki köşe arasında kalmasın diye. Çıktıya girmezler.
  final step = math.max(r / 3, 0.25);
  final dense = <({InkPoint p, bool orig})>[(p: pts.first, orig: true)];
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i], b = pts[i + 1];
    final dx = b.x - a.x, dy = b.y - a.y;
    final n = (math.sqrt(dx * dx + dy * dy) / step).ceil();
    for (var k = 1; k < n; k++) {
      dense.add((p: _lerp(a, b, k / n), orig: false));
    }
    dense.add((p: b, orig: true));
  }

  // [out] silgi dışında, [inn] içinde olan iki komşu yoğun nokta arasında sınır.
  InkPoint boundary(InkPoint out, InkPoint inn) {
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (hit(_lerp(out, inn, mid))) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return _lerp(out, inn, lo);
  }

  final pieces = <List<InkPoint>>[];
  var cur = <InkPoint>[];
  void flush() {
    if (cur.length >= 2) pieces.add(cur);
    cur = <InkPoint>[];
  }

  var prevInside = hit(dense.first.p);
  if (!prevInside) cur.add(dense.first.p);
  for (var i = 1; i < dense.length; i++) {
    final d = dense[i];
    final inside = hit(d.p);
    if (!prevInside && inside) {
      cur.add(boundary(dense[i - 1].p, d.p)); // çıkış sınırı
      flush();
    } else if (prevInside && !inside) {
      cur.add(boundary(d.p, dense[i - 1].p)); // giriş sınırı
      if (d.orig) cur.add(d.p);
    } else if (!inside && d.orig) {
      cur.add(d.p);
    }
    prevInside = inside;
  }
  flush();
  String name(int i) => idFor != null ? idFor(stroke.id, i) : _uuid.v4();
  return EraseResult([
    for (var i = 0; i < pieces.length; i++) stroke.copyWith(id: name(i), points: pieces[i]),
  ], true);
}
