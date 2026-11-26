/// Yakınlaştırma/kaydırma sırasında çizgi çiziminin hafifletilmesi için saf
/// yardımcılar (Flutter'a bağlı değil): görünür olanı seç, nokta bütçesi, noktaları seyrelt.

/// Eksen hizalı dikdörtgen (sayfa birimi).
class LodRect {
  const LodRect(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  bool overlaps(LodRect o) => left <= o.right && right >= o.left && top <= o.bottom && bottom >= o.top;

  LodRect inflate(double d) => LodRect(left - d, top - d, right + d, bottom + d);

  double get width => right - left;
  double get height => bottom - top;
}

/// [bounds] içinde [viewport] ile kesişenlerin sıraları (artan; çizim sırası korunur).
List<int> visibleStrokes(List<LodRect> bounds, LodRect viewport) => [
  for (var i = 0; i < bounds.length; i++)
    if (bounds[i].overlaps(viewport)) i,
];

/// Nokta bütçesi: [counts] çizgilerin nokta sayıları (eskiden yeniye). En yeni çizgilerden
/// başlayıp toplam [budget]'ı aşmayana dek tutar; en yeni çizgi her zaman tutulur.
/// Dönüş: her çizgi için tutuldu mu.
List<bool> pointBudget(List<int> counts, int budget) {
  final keep = List<bool>.filled(counts.length, false);
  var used = 0;
  for (var i = counts.length - 1; i >= 0; i--) {
    if (used + counts[i] > budget && used > 0) continue;
    used += counts[i];
    keep[i] = true;
  }
  return keep;
}

/// Douglas-Peucker (yinelemeli): [tolerance]'tan yakın noktalar atılır; uçlar kalır.
List<P> simplifyPoints<P>(List<P> pts, double tolerance, double Function(P) x, double Function(P) y) {
  final n = pts.length;
  if (n < 3 || tolerance <= 0) return pts;
  final keep = List<bool>.filled(n, false);
  keep[0] = keep[n - 1] = true;
  final stack = <(int, int)>[(0, n - 1)];
  final tol2 = tolerance * tolerance;
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    if (b <= a + 1) continue;
    final ax = x(pts[a]), ay = y(pts[a]), dx = x(pts[b]) - ax, dy = y(pts[b]) - ay;
    final len2 = dx * dx + dy * dy;
    var worst = -1.0;
    var wi = -1;
    for (var i = a + 1; i < b; i++) {
      final px = x(pts[i]) - ax, py = y(pts[i]) - ay;
      double d2;
      if (len2 == 0) {
        d2 = px * px + py * py;
      } else {
        var t = (px * dx + py * dy) / len2;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        final ex = px - t * dx, ey = py - t * dy;
        d2 = ex * ex + ey * ey;
      }
      if (d2 > worst) {
        worst = d2;
        wi = i;
      }
    }
    if (worst > tol2) {
      keep[wi] = true;
      stack.add((a, wi));
      stack.add((wi, b));
    }
  }
  return [
    for (var i = 0; i < n; i++)
      if (keep[i]) pts[i],
  ];
}
