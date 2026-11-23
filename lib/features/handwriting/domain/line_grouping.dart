/// Çizgileri satırlara ayırır (saf Dart). Tanıyıcı TEK satır varsayar; bu yüzden
/// önce satır bulunur: gövde çizgileri y-merkezine göre kümelenir (eğik yazı için
/// en yakın x komşusuyla), nokta/virgül/aksan gibi küçük çizgiler en yakın satıra
/// bağlanır, yan yana kalmış parçalar birleştirilir. Şekil, çok uzun düz çizgi,
/// silinmiş çizgi ve fosforlu atlanır (şekil isteğe bağlı "[şekil]" satırı olur).
library;

import 'dart:math' as math;

import '../../ink/domain/ink_stroke_record.dart';
import 'handwriting_recognizer.dart';

class GroupingOptions {
  const GroupingOptions({
    this.bandFactor = 0.55,
    this.mergeOverlap = 0.6,
    this.smallFactor = 0.5,
    this.smallReach = 1.0,
    this.maxStraightLength = 420,
    this.shapeMinSize = 140,
    this.markShapes = false,
  });

  /// Bir çizgi, satırdaki en yakın komşunun y-merkezinden en çok bu kat (satır
  /// yüksekliği ile) uzaksa aynı satırdadır.
  final double bandFactor;

  /// İki satırın y-bandı bu oranın üstünde örtüşüyor ve yatayda ayrıysa tek satır.
  final double mergeOverlap;

  /// Yüksekliği gövde medyanının bu katından küçük çizgi "küçük"tür (nokta, aksan).
  final double smallFactor;

  /// Küçük çizginin satıra uzaklığı en çok bu kat (satır yüksekliği) olmalı.
  final double smallReach;

  /// Bundan uzun neredeyse düz çizgi (cetvel, tablo çizgisi) atlanır.
  final double maxStraightLength;

  /// İki kenarı da bundan büyük kapalı çizgi şekil sayılır.
  final double shapeMinSize;

  /// true: şekiller "[şekil]" satırı olur; false: atlanır.
  final bool markShapes;
}

/// Tek satırın çizgileri (soldan sağa sıralı).
class StrokeLineGroup {
  const StrokeLineGroup({
    required this.strokes,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.bodyHeight,
    this.isShape = false,
  });

  final List<InkStroke> strokes;
  final double left, top, right, bottom;

  /// Gövde çizgilerinin medyan yüksekliği (satır "harf boyu").
  final double bodyHeight;
  final bool isShape;

  double get width => right - left;
  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;
  List<String> get strokeIds => [for (final s in strokes) s.id];
}

class GroupingResult {
  const GroupingResult(this.lines, this.skippedIds);

  /// Yukarıdan aşağı sırayla.
  final List<StrokeLineGroup> lines;

  /// Atlanan çizgi kimlikleri (silinmiş olanlar hariç).
  final List<String> skippedIds;
}

class _B {
  _B(this.s, this.l, this.t, this.r, this.b, this.pathLen, this.chord);
  final InkStroke s;
  final double l, t, r, b, pathLen, chord;
  double get w => r - l;
  double get h => b - t;
  double get cx => (l + r) / 2;
  double get cy => (t + b) / 2;
  double get diag => math.sqrt(w * w + h * h);
}

_B? _box(InkStroke s) {
  final p = s.points;
  if (p.isEmpty) return null;
  var l = p.first.x, r = p.first.x, t = p.first.y, b = p.first.y, len = 0.0;
  for (var i = 0; i < p.length; i++) {
    final q = p[i];
    l = math.min(l, q.x);
    r = math.max(r, q.x);
    t = math.min(t, q.y);
    b = math.max(b, q.y);
    if (i > 0) len += math.sqrt(math.pow(q.x - p[i - 1].x, 2) + math.pow(q.y - p[i - 1].y, 2));
  }
  final chord = math.sqrt(math.pow(p.last.x - p.first.x, 2) + math.pow(p.last.y - p.first.y, 2));
  return _B(s, l, t, r, b, len, chord);
}

double _median(List<double> v) {
  final s = [...v]..sort();
  if (s.isEmpty) return 0;
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

class _Line {
  _Line(_B first) : members = [first];
  final List<_B> members;

  double get l => members.map((m) => m.l).reduce(math.min);
  double get r => members.map((m) => m.r).reduce(math.max);
  double get t => members.map((m) => m.t).reduce(math.min);
  double get b => members.map((m) => m.b).reduce(math.max);
  double get medH => _median([for (final m in members) m.h]);
  double get medCy => _median([for (final m in members) m.cy]);

  /// [x] konumuna yatayda en yakın üyenin y-merkezi.
  double cyNear(_B o) {
    var best = members.first;
    var bd = double.infinity;
    for (final m in members) {
      final gap = math.max(0.0, math.max(m.l - o.r, o.l - m.r));
      if (gap < bd) {
        bd = gap;
        best = m;
      }
    }
    return best.cy;
  }
}

/// [strokes]'u satırlara ayırır. Boş ya da yalnız silinmiş/atlanan çizgi: boş sonuç.
GroupingResult groupStrokesIntoLines(Iterable<InkStroke> strokes, {GroupingOptions options = const GroupingOptions()}) {
  final skipped = <String>[];
  final text = <_B>[];
  final shapeBoxes = <_B>[];
  for (final s in strokes) {
    if (s.deleted) continue;
    final name = s.tool.split(':').first;
    if (name == 'highlighter' || name == 'eraser') {
      skipped.add(s.id);
      continue;
    }
    final b = _box(s);
    if (b == null) {
      skipped.add(s.id);
      continue;
    }
    if (b.pathLen > 0 && b.chord / b.pathLen >= 0.96 && b.chord >= options.maxStraightLength) {
      skipped.add(s.id); // cetvel/tablo çizgisi
      continue;
    }
    final big = b.w >= options.shapeMinSize && b.h >= options.shapeMinSize;
    final closed = b.diag > 0 && b.chord <= b.diag * 0.25;
    if (big && (closed || (b.w >= options.shapeMinSize * 2 && b.h >= options.shapeMinSize * 2))) {
      if (options.markShapes) {
        shapeBoxes.add(b);
      } else {
        skipped.add(s.id);
      }
      continue;
    }
    text.add(b);
  }

  final lines = <_Line>[];
  if (text.isNotEmpty) {
    final m0 = _median([for (final b in text) b.h]);
    var body = [for (final b in text) if (b.h >= m0 * options.smallFactor) b];
    if (body.isEmpty) body = [...text];
    final ref = math.max(1.0, _median([for (final b in body) b.h]));
    final small = [for (final b in text) if (!body.contains(b)) b];

    lines.addAll(_cluster(body, ref, options));
    _mergeSideBySide(lines, options);

    // Küçük çizgiler: en yakın satıra (uzaklık ≤ smallReach * ref), yoksa kendi satırı.
    final leftovers = <_B>[];
    for (final b in small) {
      _Line? best;
      var bd = double.infinity;
      for (final ln in lines) {
        final dy = math.max(0.0, math.max(ln.t - b.b, b.t - ln.b));
        var dx = double.infinity;
        for (final m in ln.members) {
          dx = math.min(dx, math.max(0.0, math.max(m.l - b.r, b.l - m.r)));
        }
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < bd) {
          bd = d;
          best = ln;
        }
      }
      if (best != null && bd <= options.smallReach * ref) {
        best.members.add(b);
      } else {
        leftovers.add(b);
      }
    }
    if (leftovers.isNotEmpty) {
      final lref = math.max(1.0, _median([for (final b in leftovers) math.max(b.h, b.w)]));
      lines.addAll(_cluster(leftovers, lref, options));
    }
  }

  final out = <StrokeLineGroup>[];
  for (final ln in lines) {
    final ms = [...ln.members]..sort((a, b) {
        final c = a.l.compareTo(b.l);
        return c != 0 ? c : a.s.startedAtMs.compareTo(b.s.startedAtMs);
      });
    out.add(StrokeLineGroup(
      strokes: [for (final m in ms) m.s],
      left: ln.l,
      top: ln.t,
      right: ln.r,
      bottom: ln.b,
      bodyHeight: ln.medH,
    ));
  }
  out.addAll(_shapeGroups(shapeBoxes));
  out.sort((a, b) => a.centerY.compareTo(b.centerY));
  return GroupingResult(out, skipped);
}

List<_Line> _cluster(List<_B> items, double ref, GroupingOptions o) {
  final sorted = [...items]..sort((a, b) {
      final c = a.cy.compareTo(b.cy);
      return c != 0 ? c : a.cx.compareTo(b.cx);
    });
  final lines = <_Line>[];
  for (final b in sorted) {
    _Line? best;
    var bd = double.infinity;
    for (final ln in lines) {
      final d = (b.cy - ln.cyNear(b)).abs();
      if (d < bd) {
        bd = d;
        best = ln;
      }
    }
    if (best != null && bd <= o.bandFactor * ref) {
      best.members.add(b);
    } else {
      lines.add(_Line(b));
    }
  }
  return lines;
}

/// Aynı satırın yan yana kalmış parçalarını birleştirir: y-bandı örtüşen ve
/// yatayda neredeyse ayrık satırlar. Üst üste duran satırlar (yatay örtüşme
/// fazla) birleşmez.
void _mergeSideBySide(List<_Line> lines, GroupingOptions o) {
  var changed = true;
  while (changed) {
    changed = false;
    outer:
    for (var i = 0; i < lines.length; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final a = lines[i], b = lines[j];
        final ha = math.max(1.0, a.medH), hb = math.max(1.0, b.medH);
        final aLo = a.medCy - ha / 2, aHi = a.medCy + ha / 2;
        final bLo = b.medCy - hb / 2, bHi = b.medCy + hb / 2;
        final overlapY = math.min(aHi, bHi) - math.max(aLo, bLo);
        if (overlapY / math.min(ha, hb) < o.mergeOverlap) continue;
        final overlapX = math.min(a.r, b.r) - math.max(a.l, b.l);
        final narrow = math.min(a.r - a.l, b.r - b.l);
        if (narrow > 0 && overlapX / narrow >= 0.5) continue;
        a.members.addAll(b.members);
        lines.removeAt(j);
        changed = true;
        break outer;
      }
    }
  }
}

List<StrokeLineGroup> _shapeGroups(List<_B> boxes) {
  final groups = <List<_B>>[];
  for (final b in boxes) {
    final touching = [
      for (final g in groups)
        if (g.any((m) => m.l <= b.r && b.l <= m.r && m.t <= b.b && b.t <= m.b)) g,
    ];
    final merged = <_B>[b];
    for (final g in touching) {
      merged.addAll(g);
      groups.remove(g);
    }
    groups.add(merged);
  }
  return [
    for (final g in groups)
      StrokeLineGroup(
        strokes: [for (final m in g) m.s],
        left: g.map((m) => m.l).reduce(math.min),
        top: g.map((m) => m.t).reduce(math.min),
        right: g.map((m) => m.r).reduce(math.max),
        bottom: g.map((m) => m.b).reduce(math.max),
        bodyHeight: _median([for (final m in g) m.h]),
        isShape: true,
      ),
  ];
}

/// Satırı tanıyıcıya verilecek biçime çevirir: noktalar satır sol-üstüne taşınır,
/// çizgiler soldan sağa sıralı, zaman DAİMA artan (çizgiler arası 120 ms) ve yazı
/// alanı bir satır kadar yüksektir.
({List<List<InkSample>> strokes, RecognizerArea area}) toRecognizerInk(StrokeLineGroup g) {
  final pad = math.max(2.0, g.bodyHeight * 0.25);
  final out = <List<InkSample>>[];
  var clock = 0;
  for (final s in g.strokes) {
    final p = s.points;
    if (p.isEmpty) continue;
    final dur = p.last.t - p.first.t;
    final step = dur > 0 ? null : 8; // zamansız çizgide yapay aralık
    final samples = <InkSample>[];
    var lastT = clock;
    for (var i = 0; i < p.length; i++) {
      var t = clock + (step != null ? i * step : p[i].t - p.first.t);
      if (t < lastT) t = lastT;
      lastT = t;
      samples.add(InkSample(p[i].x - g.left + pad, p[i].y - g.top + pad, t));
    }
    out.add(samples);
    clock = lastT + 120;
  }
  final h = math.max(g.height, g.bodyHeight * 1.5) + 2 * pad;
  return (strokes: out, area: RecognizerArea(g.width + 2 * pad, h));
}
