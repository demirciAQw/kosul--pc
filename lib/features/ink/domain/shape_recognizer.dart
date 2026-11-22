/// Çizip basılı tutunca şekil düzeltme (saf geometri, model yok).
library;

import 'dart:math' as math;

import 'ink_models.dart';

enum ShapeType { line, circle, ellipse, rectangle, quadrilateral, triangle }

class ShapeResult {
  const ShapeResult(this.type, this.keyPoints, this.confidence, this.points);

  final ShapeType type;

  /// Çizgi: iki uç. Çokgen: köşeler. Daire/elips: merkez, sonra (yarı eksen a,
  /// yarı eksen b) noktası olarak (x=a, y=b) ve dönüklük (x=açı, y=0).
  final List<InkPoint> keyPoints;

  /// 0..1; eşiğin altı null döner.
  final double confidence;

  /// Düzeltilmiş çizgi noktaları (kapalı şekillerde ilk=son).
  final List<InkPoint> points;
}

const double shapeMinConfidence = 0.5;

class _P {
  const _P(this.x, this.y);
  final double x, y;
}

double _d(_P a, _P b) => math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

List<_P> _resample(List<InkPoint> pts, int n, double total) {
  final out = <_P>[_P(pts.first.x, pts.first.y)];
  final step = total / (n - 1);
  var acc = 0.0;
  var prev = out.first;
  for (var i = 1; i < pts.length; i++) {
    var cur = _P(pts[i].x, pts[i].y);
    var seg = _d(prev, cur);
    while (seg > 0 && acc + seg >= step && out.length < n) {
      final t = (step - acc) / seg;
      final q = _P(prev.x + (cur.x - prev.x) * t, prev.y + (cur.y - prev.y) * t);
      out.add(q);
      prev = q;
      seg = _d(prev, cur);
      acc = 0;
    }
    acc += seg;
    prev = cur;
  }
  while (out.length < n) {
    out.add(_P(pts.last.x, pts.last.y));
  }
  return out;
}

double _segDist(_P a, _P b, _P p) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final len2 = dx * dx + dy * dy;
  var t = 0.0;
  if (len2 > 0) t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
  return _d(_P(a.x + t * dx, a.y + t * dy), p);
}

void _dp(List<_P> p, int lo, int hi, double eps, List<bool> keep) {
  if (hi <= lo + 1) return;
  var worst = -1.0;
  var idx = -1;
  for (var i = lo + 1; i < hi; i++) {
    final d = _segDist(p[lo], p[hi], p[i]);
    if (d > worst) {
      worst = d;
      idx = i;
    }
  }
  if (worst > eps && idx >= 0) {
    keep[idx] = true;
    _dp(p, lo, idx, eps, keep);
    _dp(p, idx, hi, eps, keep);
  }
}

double _angleAt(_P prev, _P v, _P next) {
  final a1 = math.atan2(prev.y - v.y, prev.x - v.x);
  final a2 = math.atan2(next.y - v.y, next.x - v.x);
  var d = (a1 - a2).abs();
  if (d > math.pi) d = 2 * math.pi - d;
  return d; // 0..pi, pi = düz
}

double _meanDistToPolygon(List<_P> pts, List<_P> poly) {
  var sum = 0.0;
  for (final p in pts) {
    var best = double.infinity;
    for (var i = 0; i < poly.length; i++) {
      final dd = _segDist(poly[i], poly[(i + 1) % poly.length], p);
      if (dd < best) best = dd;
    }
    sum += best;
  }
  return sum / pts.length;
}

InkPoint _ip(double x, double y, double pressure) => InkPoint(x: x, y: y, pressure: pressure);

/// Titreme (nokta başına gürültü) yol uzunluğunu şişirmesin: 5'li hareketli
/// ortalama, uçlar sabit.
List<InkPoint> _smooth(List<InkPoint> p) {
  const w = 2;
  return [
    for (var i = 0; i < p.length; i++)
      if (i == 0 || i == p.length - 1)
        () {
          // Uçlar: en yakın 3 noktanın ortalaması.
          final r = i == 0 ? [0, 1, 2] : [i, i - 1, i - 2];
          var x = 0.0, y = 0.0;
          for (final j in r) {
            x += p[j].x;
            y += p[j].y;
          }
          return InkPoint(x: x / 3, y: y / 3, pressure: p[i].pressure);
        }()
      else
        () {
          final k = math.min(w, math.min(i, p.length - 1 - i));
          var x = 0.0, y = 0.0;
          for (var j = i - k; j <= i + k; j++) {
            x += p[j].x;
            y += p[j].y;
          }
          final c = 2 * k + 1;
          return InkPoint(x: x / c, y: y / c, pressure: p[i].pressure);
        }(),
  ];
}

/// Çizgiyi tanır; tanıyamazsa ya da güven eşiğin altındaysa null.
ShapeResult? recognizeShape(List<InkPoint> raw) {
  if (raw.length < 5) return null;
  final points = _smooth(raw);
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += _d(_P(points[i - 1].x, points[i - 1].y), _P(points[i].x, points[i].y));
  }
  if (total <= 0) return null;
  final pressure = points.fold<double>(0, (s, p) => s + p.pressure) / points.length;
  const n = 64;
  final rs = _resample(points, n, total);
  final gap = _d(rs.first, rs.last);
  final closed = gap <= 0.2 * total;

  ShapeResult? best;
  void consider(ShapeResult? r) {
    if (r != null && r.confidence >= shapeMinConfidence && (best == null || r.confidence > best!.confidence)) {
      best = r;
    }
  }

  if (!closed) {
    consider(_line(rs, total, pressure));
    return best;
  }
  final ell = _ellipse(rs, pressure);
  final poly = _polygon(rs, total, pressure);
  consider(poly);
  consider(ell);
  return best;
}

ShapeResult? _line(List<_P> rs, double total, double pressure) {
  final a = rs.first, b = rs.last;
  final chord = _d(a, b);
  if (chord < 1e-9 || chord / total < 0.8) return null;
  var sum = 0.0, mx = 0.0;
  for (final p in rs) {
    final dd = _segDist(a, b, p);
    sum += dd;
    if (dd > mx) mx = dd;
  }
  final mean = sum / rs.length / chord;
  if (mx / chord > 0.12) return null;
  final conf = (1 - mean / 0.04).clamp(0.0, 1.0);
  final ka = _ip(a.x, a.y, pressure), kb = _ip(b.x, b.y, pressure);
  return ShapeResult(ShapeType.line, [ka, kb], conf, [ka, kb]);
}

ShapeResult? _ellipse(List<_P> rs, double pressure) {
  var cx = 0.0, cy = 0.0;
  for (final p in rs) {
    cx += p.x;
    cy += p.y;
  }
  cx /= rs.length;
  cy /= rs.length;
  var sxx = 0.0, syy = 0.0, sxy = 0.0;
  for (final p in rs) {
    final dx = p.x - cx, dy = p.y - cy;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final c = math.cos(theta), s = math.sin(theta);
  var minU = double.infinity, maxU = -double.infinity;
  var minV = double.infinity, maxV = -double.infinity;
  for (final p in rs) {
    final dx = p.x - cx, dy = p.y - cy;
    final u = dx * c + dy * s, v = -dx * s + dy * c;
    minU = math.min(minU, u);
    maxU = math.max(maxU, u);
    minV = math.min(minV, v);
    maxV = math.max(maxV, v);
  }
  final a = (maxU - minU) / 2, b = (maxV - minV) / 2;
  if (a < 1e-9 || b < 1e-9) return null;
  // Merkez: kutunun ortası (eksen yönünde).
  final mu = (maxU + minU) / 2, mv = (maxV + minV) / 2;
  final ox = cx + mu * c - mv * s, oy = cy + mu * s + mv * c;
  var err = 0.0;
  for (final p in rs) {
    final dx = p.x - ox, dy = p.y - oy;
    final u = (dx * c + dy * s) / a, v = (-dx * s + dy * c) / b;
    err += (math.sqrt(u * u + v * v) - 1).abs();
  }
  err /= rs.length;
  final conf = (1 - err / 0.12).clamp(0.0, 1.0);
  final isCircle = (a - b).abs() / math.max(a, b) < 0.15;
  final rad = (a + b) / 2;
  final pts = <InkPoint>[];
  const m = 48;
  for (var i = 0; i <= m; i++) {
    final t = 2 * math.pi * i / m;
    final u = (isCircle ? rad : a) * math.cos(t);
    final v = (isCircle ? rad : b) * math.sin(t);
    pts.add(_ip(ox + u * c - v * s, oy + u * s + v * c, pressure));
  }
  return ShapeResult(
    isCircle ? ShapeType.circle : ShapeType.ellipse,
    [
      _ip(ox, oy, pressure),
      _ip(isCircle ? rad : a, isCircle ? rad : b, pressure),
      _ip(isCircle ? 0 : theta, 0, pressure),
    ],
    conf,
    pts,
  );
}

/// Yuvarlanmış bir köşeyi iki yakın köşe olarak bırakmasın: komşu kenarların
/// kesişimiyle tek köşeye indir.
List<_P> _mergeCorners(List<_P> v, double near) {
  var cur = v;
  var again = true;
  while (again && cur.length > 3) {
    again = false;
    final m = cur.length;
    for (var i = 0; i < m; i++) {
      final a = cur[i], b = cur[(i + 1) % m];
      if (_d(a, b) >= near) continue;
      final p0 = cur[(i - 1 + m) % m], p3 = cur[(i + 2) % m];
      final x = _intersection(p0, a, b, p3);
      final mid = _P((a.x + b.x) / 2, (a.y + b.y) / 2);
      final merged = (x != null && _d(x, mid) < 2 * near) ? x : mid;
      final next = <_P>[];
      for (var k = 0; k < m; k++) {
        if (k == i) {
          next.add(merged);
        } else if (k != (i + 1) % m) {
          next.add(cur[k]);
        }
      }
      cur = next;
      again = true;
      break;
    }
  }
  return cur;
}

bool _cross4(_P a, _P b, _P c, _P d) {
  double cr(_P o, _P p, _P q) => (p.x - o.x) * (q.y - o.y) - (p.y - o.y) * (q.x - o.x);
  final d1 = cr(c, d, a), d2 = cr(c, d, b);
  final d3 = cr(a, b, c), d4 = cr(a, b, d);
  return d1 * d2 < 0 && d3 * d4 < 0;
}

_P? _intersection(_P a, _P b, _P c, _P d) {
  final r1x = b.x - a.x, r1y = b.y - a.y, r2x = d.x - c.x, r2y = d.y - c.y;
  final den = r1x * r2y - r1y * r2x;
  if (den.abs() < 1e-9) return null;
  final t = ((c.x - a.x) * r2y - (c.y - a.y) * r2x) / den;
  return _P(a.x + t * r1x, a.y + t * r1y);
}

ShapeResult? _polygon(List<_P> rs, double total, double pressure) {
  final loop = [...rs.sublist(0, rs.length - 1), rs.first];
  final keep = List<bool>.filled(loop.length, false);
  keep.first = true;
  keep.last = true;
  _dp(loop, 0, loop.length - 1, 0.025 * total, keep);
  var v = <_P>[
    for (var i = 0; i < loop.length - 1; i++)
      if (keep[i]) loop[i],
  ];
  v = _mergeCorners(v, 0.1 * total);
  // Düz sayılan (başlangıç noktası gibi) ve çok yakın köşeleri ele.
  var changed = true;
  while (changed && v.length > 3) {
    changed = false;
    for (var i = 0; i < v.length; i++) {
      final prev = v[(i - 1 + v.length) % v.length];
      final next = v[(i + 1) % v.length];
      if (_angleAt(prev, v[i], next) > 150 * math.pi / 180 || _d(prev, v[i]) < 0.06 * total) {
        v = [...v.sublist(0, i), ...v.sublist(i + 1)];
        changed = true;
        break;
      }
    }
  }
  if (v.length != 3 && v.length != 4) return null;
  // Kendini kesen dörtgen (sekiz, kelebek) şekil sayılmaz.
  if (v.length == 4 && (_cross4(v[0], v[1], v[2], v[3]) || _cross4(v[1], v[2], v[3], v[0]))) {
    return null;
  }
  final err = _meanDistToPolygon(rs, v) / total;
  var conf = (1 - err / 0.02).clamp(0.0, 1.0);
  var type = v.length == 3 ? ShapeType.triangle : ShapeType.quadrilateral;
  var corners = v;
  if (v.length == 4) {
    var rectLike = true;
    for (var i = 0; i < 4; i++) {
      final ang = _angleAt(v[(i + 3) % 4], v[i], v[(i + 1) % 4]);
      if ((ang - math.pi / 2).abs() > 18 * math.pi / 180) rectLike = false;
    }
    if (rectLike) {
      // Kenar yönlerinin ortalaması (mod 90 derece) ile eksene hizalı kutu.
      var sx = 0.0, sy = 0.0;
      for (var i = 0; i < 4; i++) {
        final a = v[i], b = v[(i + 1) % 4];
        final ang = math.atan2(b.y - a.y, b.x - a.x) * 4;
        sx += math.cos(ang);
        sy += math.sin(ang);
      }
      final th = math.atan2(sy, sx) / 4;
      final c = math.cos(th), s = math.sin(th);
      var mnU = double.infinity, mxU = -double.infinity;
      var mnV = double.infinity, mxV = -double.infinity;
      for (final p in v) {
        final u = p.x * c + p.y * s, w = -p.x * s + p.y * c;
        mnU = math.min(mnU, u);
        mxU = math.max(mxU, u);
        mnV = math.min(mnV, w);
        mxV = math.max(mxV, w);
      }
      var wU = mxU - mnU, wV = mxV - mnV;
      if (wU > 0 && wV > 0 && (wU - wV).abs() / math.max(wU, wV) < 0.1) {
        final m = (wU + wV) / 2;
        final cu = (mnU + mxU) / 2, cv = (mnV + mxV) / 2;
        mnU = cu - m / 2;
        mxU = cu + m / 2;
        mnV = cv - m / 2;
        mxV = cv + m / 2;
      }
      _P back(double u, double w) => _P(u * c - w * s, u * s + w * c);
      corners = [back(mnU, mnV), back(mxU, mnV), back(mxU, mxV), back(mnU, mxV)];
      type = ShapeType.rectangle;
      conf = (1 - _meanDistToPolygon(rs, corners) / total / 0.02).clamp(0.0, 1.0);
    }
  }
  final keys = [for (final p in corners) _ip(p.x, p.y, pressure)];
  return ShapeResult(type, keys, conf, [...keys, keys.first]);
}

/// Doğrudan çizilen şekil araçları (sürükle, bırakınca mükemmel şekil).
enum ShapeTool { line, arrow, circle, ellipse, rectangle, triangle }

/// [p0] (basılan nokta) ile [p1] (şimdiki nokta) köşegen olarak verilen şekli üretir.
/// Çizgi/ok: p0'dan p1'e. Daire: kutunun kısa kenarına sığan daire (kutunun ortasında).
/// Elips/dikdörtgen: kutu. Üçgen: tepesi kutunun üst ortasında, tabanı alt kenarda.
/// Kapalı şekillerde ilk nokta = son nokta. Dejenere (aynı nokta) girdide boş liste.
List<InkPoint> buildShape(ShapeTool type, InkPoint p0, InkPoint p1) {
  final dx = p1.x - p0.x, dy = p1.y - p0.y;
  if (!dx.isFinite || !dy.isFinite) return const [];
  final pr = (p0.pressure + p1.pressure) / 2;
  InkPoint ip(double x, double y) => InkPoint(x: x, y: y, pressure: pr);
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1e-6) return const [];
  final l = math.min(p0.x, p1.x), r = math.max(p0.x, p1.x);
  final t = math.min(p0.y, p1.y), b = math.max(p0.y, p1.y);
  final cx = (l + r) / 2, cy = (t + b) / 2;
  switch (type) {
    case ShapeTool.line:
      return [ip(p0.x, p0.y), ip(p1.x, p1.y)];
    case ShapeTool.arrow:
      final head = math.min(math.max(14.0, len * 0.2), len * 0.5);
      final ang = math.atan2(dy, dx);
      const wing = 0.45; // ~26 derece
      InkPoint w(double a) => ip(p1.x - head * math.cos(ang + a), p1.y - head * math.sin(ang + a));
      return [ip(p0.x, p0.y), ip(p1.x, p1.y), w(wing), ip(p1.x, p1.y), w(-wing)];
    case ShapeTool.circle:
    case ShapeTool.ellipse:
      final a = type == ShapeTool.circle ? math.min(r - l, b - t) / 2 : (r - l) / 2;
      final c = type == ShapeTool.circle ? a : (b - t) / 2;
      if (a < 1e-6 || c < 1e-6) return const [];
      const n = 48;
      return [
        for (var i = 0; i <= n; i++) ip(cx + a * math.cos(2 * math.pi * i / n), cy + c * math.sin(2 * math.pi * i / n)),
      ];
    case ShapeTool.rectangle:
      if (r - l < 1e-6 || b - t < 1e-6) return const [];
      return [ip(l, t), ip(r, t), ip(r, b), ip(l, b), ip(l, t)];
    case ShapeTool.triangle:
      if (r - l < 1e-6 || b - t < 1e-6) return const [];
      return [ip(cx, t), ip(r, b), ip(l, b), ip(cx, t)];
  }
}

String shapeToolLabel(ShapeTool t) => switch (t) {
  ShapeTool.line => 'Düz çizgi',
  ShapeTool.arrow => 'Ok',
  ShapeTool.circle => 'Daire',
  ShapeTool.ellipse => 'Elips',
  ShapeTool.rectangle => 'Dikdörtgen',
  ShapeTool.triangle => 'Üçgen',
};
