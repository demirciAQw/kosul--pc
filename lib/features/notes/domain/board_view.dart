import 'dart:math' as math;

import 'board_layout.dart';
import 'page_board.dart';

/// Pano görünümü ve geometrisi (saf Dart). Birim: pano birimi; ekran = pano * ölçek + öteleme.

const boardMinScale = 0.02;
const boardMaxScale = 4.0;

/// Bu ölçeğin altında kartlar düşük ayrıntıyla çizilir (başlık + renk).
const boardLowDetailScale = 0.15;

/// Görünüm: ölçek ve öteleme (ekran pikseli). Değişmez.
class BoardViewport {
  const BoardViewport({this.scale = 1, this.tx = 0, this.ty = 0});
  final double scale;
  final double tx;
  final double ty;

  static double clampScale(double s) => s.isNaN ? 1.0 : s.clamp(boardMinScale, boardMaxScale);

  BoardPoint toWorld(double sx, double sy) => BoardPoint((sx - tx) / scale, (sy - ty) / scale);
  BoardPoint toScreen(double wx, double wy) => BoardPoint(wx * scale + tx, wy * scale + ty);

  /// Ekran noktası [fx],[fy] sabit kalacak biçimde ölçeği [factor] katı yapar ([boardMinScale]..[boardMaxScale]).
  BoardViewport zoomAt(double fx, double fy, double factor) {
    final s = clampScale(scale * factor);
    final w = toWorld(fx, fy);
    return BoardViewport(scale: s, tx: fx - w.x * s, ty: fy - w.y * s);
  }

  BoardViewport panned(double dx, double dy) => BoardViewport(scale: scale, tx: tx + dx, ty: ty + dy);

  /// Ekranda ([w] x [h]) görünen pano dikdörtgeni.
  BoardRect visibleRect(double w, double h) {
    final a = toWorld(0, 0);
    return BoardRect(a.x, a.y, w / scale, h / scale);
  }

  /// [rect] bölgesini [w] x [h] ekrana [padding] pikselle sığdırır; ölçek en çok [maxScale].
  static BoardViewport fit(BoardRect rect, double w, double h, {double padding = 32, double maxScale = 1.0}) {
    final aw = math.max(1.0, w - 2 * padding);
    final ah = math.max(1.0, h - 2 * padding);
    final s = clampScale(math.min(math.min(aw / math.max(rect.w, 1), ah / math.max(rect.h, 1)), maxScale));
    return BoardViewport(scale: s, tx: w / 2 - rect.cx * s, ty: h / 2 - rect.cy * s);
  }

  /// [c] noktasını ekran ortasına getirir (ölçek aynı).
  BoardViewport centeredOn(double cx, double cy, double w, double h) => BoardViewport(scale: scale, tx: w / 2 - cx * scale, ty: h / 2 - cy * scale);

  @override
  bool operator ==(Object other) => other is BoardViewport && other.scale == scale && other.tx == tx && other.ty == ty;

  @override
  int get hashCode => Object.hash(scale, tx, ty);
}

/// Yerleşmiş kartların kapsayan dikdörtgeni (yoksa null).
BoardRect? boundsOf(Iterable<BoardRect> rects) {
  var any = false;
  var l = 0.0, t = 0.0, r = 0.0, b = 0.0;
  for (final c in rects) {
    if (!any) {
      l = c.x;
      t = c.y;
      r = c.right;
      b = c.bottom;
      any = true;
    } else {
      l = math.min(l, c.x);
      t = math.min(t, c.y);
      r = math.max(r, c.right);
      b = math.max(b, c.bottom);
    }
  }
  return any ? BoardRect(l, t, r - l, b - t) : null;
}

/// Yalnız görünür alanla ([view], [margin] kadar genişletilmiş) kesişen kartların kimlikleri.
List<String> visibleCardIds(Map<String, BoardRect> rects, BoardRect view, {double margin = 0}) {
  final v = BoardRect(view.x - margin, view.y - margin, view.w + 2 * margin, view.h + 2 * margin);
  return [
    for (final e in rects.entries)
      if (e.value.overlaps(v)) e.key,
  ];
}

/// Yerleşmemiş kartlar için konum: yerleşmişlerin altında ızgara; hiçbiri yerleşmemişse 0,0'dan.
/// Yalnız yerleşmemiş kartlar döner. Hepsi yerleşmişse boş.
Map<String, BoardRect> placeUnplaced(List<BoardCard> cards, {int columns = 4, double gap = 80}) {
  final placed = [for (final c in cards) c.rect()].whereType<BoardRect>().toList();
  final todo = [for (final c in cards) if (!c.placed) c];
  if (todo.isEmpty) return const {};
  final top = placed.isEmpty ? 0.0 : placed.map((r) => r.bottom).reduce(math.max) + gap;
  final left = placed.isEmpty ? 0.0 : placed.map((r) => r.x).reduce(math.min);
  final out = <String, BoardRect>{};
  for (var i = 0; i < todo.length; i++) {
    out[todo[i].pageId] = BoardRect(
      left + (i % columns) * (boardCardW + gap),
      top + (i ~/ columns) * (boardCardH + gap),
      boardCardW,
      boardCardH,
    );
  }
  return out;
}

/// Pano noktasına en üstteki (son çizilen) kart; yoksa null. [skip] verilen kimlik atlanır.
String? cardAt(Map<String, BoardRect> rects, double x, double y, {String? skip}) {
  String? hit;
  for (final e in rects.entries) {
    if (e.key == skip) continue;
    final r = e.value;
    if (x >= r.x && x <= r.right && y >= r.y && y <= r.bottom) hit = e.key;
  }
  return hit;
}

/// Kartın tutamaç bölgeleri (pano birimi). [scale] küçükken ekranda kullanışlı kalsın diye
/// boyut en az ~[minPx] piksel olur.
class BoardHandles {
  BoardHandles(BoardRect card, double scale, {double minPx = 30, double worldSize = 44}) {
    final s = math.max(worldSize, minPx / scale);
    resize = BoardRect(card.right - s, card.bottom - s, s, s);
    link = BoardRect(card.right - s / 2, card.cy - s / 2, s, s);
  }

  /// Sağ-alt köşe: boyutlandırma.
  late final BoardRect resize;

  /// Sağ kenar ortası: bağla.
  late final BoardRect link;

  static bool hit(BoardRect r, double x, double y) => x >= r.x && x <= r.right && y >= r.y && y <= r.bottom;
}

/// Bağlantı eğrisi: kübik bezier (p0, c1, c2, p1).
class BoardCurve {
  const BoardCurve(this.p0, this.c1, this.c2, this.p1);
  final BoardPoint p0, c1, c2, p1;

  BoardPoint at(double t) {
    final u = 1 - t;
    final a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return BoardPoint(
      a * p0.x + b * c1.x + c * c2.x + d * p1.x,
      a * p0.y + b * c1.y + c * c2.y + d * p1.y,
    );
  }

  /// Ok ucunun yönü (radyan): eğrinin son teğeti.
  double get endAngle => math.atan2(p1.y - c2.y, p1.x - c2.x);

  /// [x],[y] noktasının eğriye en kısa uzaklığı (örneklemeyle).
  double distanceTo(double x, double y, {int samples = 32}) {
    var best = double.infinity;
    var prev = p0;
    for (var i = 1; i <= samples; i++) {
      final q = at(i / samples);
      best = math.min(best, _segDist(x, y, prev, q));
      prev = q;
    }
    return best;
  }

  static double _segDist(double x, double y, BoardPoint a, BoardPoint b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : ((x - a.x) * dx + (y - a.y) * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final px = a.x + t * dx, py = a.y + t * dy;
    return math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
  }
}

/// Uç noktasının hangi kenarda olduğuna göre dışa doğru kontrol noktası.
BoardPoint _control(BoardRect r, BoardPoint p, double d) {
  const eps = 0.5;
  if ((p.y - r.y).abs() < eps) return BoardPoint(p.x, p.y - d);
  if ((p.x - r.right).abs() < eps) return BoardPoint(p.x + d, p.y);
  if ((p.y - r.bottom).abs() < eps) return BoardPoint(p.x, p.y + d);
  return BoardPoint(p.x - d, p.y);
}

/// İki kart arasındaki eğri: uçlar [edgePoints] (kenar orta noktaları).
BoardCurve curveBetween(BoardRect a, BoardRect b) {
  final ends = edgePoints(a, b);
  final dist = math.sqrt(math.pow(ends.to.x - ends.from.x, 2) + math.pow(ends.to.y - ends.from.y, 2));
  final d = math.max(40.0, dist * 0.4);
  return BoardCurve(ends.from, _control(a, ends.from, d), _control(b, ends.to, d), ends.to);
}

/// [links] içinde [x],[y]'ye [tolerance] içinde en yakın bağlantı kimliği (yoksa null).
/// [curves]: bağlantı kimliği -> eğri.
String? linkAt(Map<String, BoardCurve> curves, double x, double y, double tolerance) {
  String? best;
  var bestD = tolerance;
  for (final e in curves.entries) {
    final d = e.value.distanceTo(x, y);
    if (d <= bestD) {
      bestD = d;
      best = e.key;
    }
  }
  return best;
}
