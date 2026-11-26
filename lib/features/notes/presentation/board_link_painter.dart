import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/board_view.dart';
import '../domain/page_board.dart';

/// Bağlantı çizgisi biçimi.
class BoardLinkStyle {
  const BoardLinkStyle({required this.color, required this.width, required this.dashed});
  final Color color;

  /// Ekran pikseli.
  final double width;
  final bool dashed;
}

/// Tür -> biçim: `konu` (konu ağacı) ince ve kesik, `child` (alt sayfa) ayrı renk, `link` kendi rengi.
BoardLinkStyle linkStyleFor(PageLinkRecord l) => switch (l.kind) {
      PageLinkKind.konu => BoardLinkStyle(color: Color(l.color).withValues(alpha: 0.7), width: 1.2, dashed: true),
      PageLinkKind.child => const BoardLinkStyle(color: Color(0xFF00897B), width: 2.5, dashed: false),
      PageLinkKind.link => BoardLinkStyle(color: Color(l.color), width: 2.5, dashed: false),
    };

/// Bağlantılar: bezier eğri + ok ucu (+ etiket). Çizim ekran uzayında (kalınlık ölçekle büyümez).
class BoardLinkPainter extends CustomPainter {
  BoardLinkPainter({
    required this.viewport,
    required this.curves,
    required this.links,
    this.selectedId,
  });

  final BoardViewport viewport;
  final Map<String, BoardCurve> curves;
  final Map<String, PageLinkRecord> links;
  final String? selectedId;

  Offset _o(BoardPoint p) {
    final s = viewport.toScreen(p.x, p.y);
    return Offset(s.x, s.y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Offset.zero & size;
    for (final e in curves.entries) {
      final link = links[e.key];
      if (link == null) continue;
      final c = e.value;
      final p0 = _o(c.p0), p1 = _o(c.p1);
      final box = Rect.fromPoints(p0, p1).inflate((p1 - p0).distance * 0.5 + 40);
      if (!box.overlaps(screen)) continue;
      final st = linkStyleFor(link);
      final sel = e.key == selectedId;
      final paint = Paint()
        ..color = sel ? Color.alphaBlend(const Color(0x66000000), st.color) : st.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = st.width + (sel ? 2 : 0)
        ..strokeCap = StrokeCap.round;
      const n = 40;
      final pts = [for (var i = 0; i <= n; i++) _o(c.at(i / n))];
      if (st.dashed) {
        for (var i = 0; i < n; i += 2) {
          canvas.drawLine(pts[i], pts[i + 1], paint);
        }
      } else {
        canvas.drawPath(Path()..addPolygon(pts, false), paint);
      }
      // Ok ucu (konu bağlantılarında küçük).
      final ang = c.endAngle;
      final len = st.dashed ? 8.0 : 13.0;
      final tip = p1;
      final fill = Paint()..color = paint.color;
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - len * math.cos(ang - 0.45), tip.dy - len * math.sin(ang - 0.45))
          ..lineTo(tip.dx - len * math.cos(ang + 0.45), tip.dy - len * math.sin(ang + 0.45))
          ..close(),
        fill,
      );
      if (link.label.isNotEmpty && viewport.scale >= boardLowDetailScale) {
        final tp = TextPainter(
          text: TextSpan(text: link.label, style: TextStyle(color: paint.color, fontSize: 12, fontWeight: FontWeight.w600, backgroundColor: const Color(0xCCFFFFFF))),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…',
        )..layout(maxWidth: 160);
        final m = _o(c.at(0.5));
        tp.paint(canvas, m - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(BoardLinkPainter old) =>
      old.viewport != viewport || old.selectedId != selectedId || !identical(old.curves, curves) || !identical(old.links, links);
}

/// Kart tutamaçları, bağlantı sürükleme çizgisi ve vurgular (kartların üstünde).
class BoardOverlayPainter extends CustomPainter {
  BoardOverlayPainter({
    required this.viewport,
    required this.visible,
    this.linkFrom,
    this.linkTo,
    this.targetId,
    this.sourceId,
    required this.color,
  });

  final BoardViewport viewport;
  final Map<String, BoardRect> visible;
  final BoardPoint? linkFrom;
  final BoardPoint? linkTo;

  /// Bağlantı bırakma hedefi (vurgulu).
  final String? targetId;

  /// Bağlantı modunda seçili kaynak.
  final String? sourceId;
  final Color color;

  Rect _r(BoardRect r) {
    final a = viewport.toScreen(r.x, r.y);
    return Rect.fromLTWH(a.x, a.y, r.w * viewport.scale, r.h * viewport.scale);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final hi = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    for (final id in [targetId, sourceId]) {
      final r = id == null ? null : visible[id];
      if (r != null) canvas.drawRRect(RRect.fromRectAndRadius(_r(r).inflate(3), const Radius.circular(10)), hi);
    }
    if (viewport.scale >= boardLowDetailScale) {
      final fill = Paint()..color = color;
      final white = Paint()..color = Colors.white;
      for (final r in visible.values) {
        final h = BoardHandles(r, viewport.scale);
        final l = _r(h.link);
        canvas.drawCircle(l.center, 10, white);
        canvas.drawCircle(l.center, 8, fill);
        final z = _r(h.resize);
        final tri = Path()
          ..moveTo(z.right - 4, z.bottom - 4)
          ..lineTo(z.right - 4, z.bottom - 18)
          ..lineTo(z.right - 18, z.bottom - 4)
          ..close();
        canvas.drawPath(tri, fill);
      }
    }
    final a = linkFrom, b = linkTo;
    if (a != null && b != null) {
      final sa = viewport.toScreen(a.x, a.y), sb = viewport.toScreen(b.x, b.y);
      canvas.drawLine(Offset(sa.x, sa.y), Offset(sb.x, sb.y), hi..strokeWidth = 3);
      canvas.drawCircle(Offset(sb.x, sb.y), 6, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(BoardOverlayPainter old) => true;
}
