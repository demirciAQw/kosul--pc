import 'dart:ui';

import 'package:perfect_freehand/perfect_freehand.dart';

import '../domain/ink_models.dart';
import '../domain/pen_profiles.dart';

/// Noktalardan dolu çizgi yolunu üretir (perfect_freehand, MIT).
/// [pressureFromDevice] false ise (fare) baskı benzetilir.
Path inkOutlinePath(List<InkPoint> points, InkBrush brush, {required bool complete, bool pressureFromDevice = true}) {
  if (points.isEmpty) return Path();
  final highlighter = brush.tool == InkTool.highlighter;
  if (brush.kind == PenKind.highlighter) return _chiselPath(points, brush.width);
  // Kalem türü verilmişse genişlik profilden: perfect_freehand yarıçapı baskıyla
  // doğrusal değiştirir; boyut/inceltme `penProfiles.widthAt` ile aynı aralığı verir.
  final profile = brush.kind == null ? null : penProfiles[brush.kind];
  final size = profile == null ? brush.width : brush.width * (profile.minFactor + profile.maxFactor) / 2;
  final thinning = profile == null
      ? (highlighter ? 0.0 : 0.55)
      : (profile.pressureSensitive
            ? (profile.maxFactor - profile.minFactor) / (profile.maxFactor + profile.minFactor)
            : 0.0);
  final options = StrokeOptions(
    size: size,
    thinning: thinning,
    smoothing: 0.5,
    streamline: 0.4,
    simulatePressure: !pressureFromDevice && !highlighter,
    isComplete: complete,
  );
  // Sertlik çizimde uygulanır (kayıt ham baskıyı taşır). Yalnızca baskıya duyarlı kalemlerde.
  final h = (profile?.pressureSensitive ?? false) ? brush.hardness : null;
  final outline = getStroke([
    for (final p in points)
      PointVector(p.x, p.y, pressureFromDevice ? (h == null ? p.pressure : pressureFactor(p.pressure, h)) : null),
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
  final profile = brush.kind == null ? null : penProfiles[brush.kind];
  final color = profile != null
      ? (profile.opacity < 1 ? base.withValues(alpha: base.a * profile.opacity) : base)
      : brush.tool == InkTool.highlighter
      ? base.withValues(alpha: base.a * 0.35)
      : base;
  return Paint()
    ..blendMode = (profile?.multiply ?? false) ? BlendMode.multiply : BlendMode.srcOver
    ..color = color
    ..style = PaintingStyle.fill
    ..isAntiAlias = true;
}

/// Fosforlu: kesik uç. Her nokta, [width] yüksekliğinde ve `width * highlighterTipRatio`
/// genişliğinde bir dikdörtgen; ardışık iki dikdörtgenin dış bükey zarfı eklenir
/// (kalem hareketiyle süpürülen alan). Tüm parçalar aynı yönde sarılır: kesişimde
/// nonZero dolgu delik açmaz, tek `drawPath` multiply'ı iki kat koyulaştırmaz.
Path _chiselPath(List<InkPoint> points, double width) {
  final hw = width * highlighterTipRatio / 2, hh = width / 2;
  List<Offset> tip(InkPoint p) => [
    Offset(p.x - hw, p.y - hh),
    Offset(p.x + hw, p.y - hh),
    Offset(p.x + hw, p.y + hh),
    Offset(p.x - hw, p.y + hh),
  ];
  final path = Path();
  void poly(List<Offset> hull) {
    if (hull.length < 3) return;
    path.addPolygon(hull, true);
  }

  poly(_hull(tip(points.first)));
  for (var i = 1; i < points.length; i++) {
    poly(_hull([...tip(points[i - 1]), ...tip(points[i])]));
  }
  return path;
}

/// Dış bükey zarf (monotone chain), hep aynı yönde (ekranda saat yönü: y aşağı).
List<Offset> _hull(List<Offset> pts) {
  final p = [...pts]..sort((a, b) => a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  double cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lower = <Offset>[];
  for (final q in p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  final upper = <Offset>[];
  for (final q in p.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}
