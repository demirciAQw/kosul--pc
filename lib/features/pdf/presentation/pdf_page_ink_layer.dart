import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/data/ink_b_controller.dart';
import '../../ink/data/ink_outline.dart';
import '../../ink/domain/ink_models.dart';
import '../domain/page_coords.dart';
import 'pdf_ink_session.dart';

/// Bir PDF sayfasının üstündeki kalem katmanı (InkSurface B denetleyicisi).
///
/// Bu katman DOKUNUŞ ALMAZ (görünüm parmakla kaydırılsın): kalem olaylarını
/// görünümü saran `PdfInkInput` alır ve ilgili sayfanın katmanına yollar.
/// Katman sayfanın ekrandaki dikdörtgenini doldurur (yakınlaştırınca büyür);
/// çizgiler sayfa biriminde saklanır, burada ölçekle çizilir.
class PdfPageInkLayer extends StatefulWidget {
  const PdfPageInkLayer({
    super.key,
    required this.session,
    required this.page,
    required this.pageWidth,
    required this.pageHeight,
  });

  final PdfInkSession session;

  /// 0'dan.
  final int page;

  /// Sayfa boyutu, PDF birimi, döndürme uygulanmış.
  final double pageWidth;
  final double pageHeight;

  @override
  State<PdfPageInkLayer> createState() => PdfPageInkLayerState();
}

class PdfPageInkLayerState extends State<PdfPageInkLayer> {
  final _ctl = InkBController();
  StreamSubscription<InkEvent>? _sub;
  PageCoords? _coords;
  late PagePen _pen = widget.session.penFor(widget.page);
  int? _pointer;
  InkPoint? _last;

  bool _erasing = false;
  final List<PenStroke> _erased = [];

  /// "Soru seç" sürüklemesi: görünüm yerel köşeleri (başlangıç, şimdiki).
  final _sel = ValueNotifier<(Offset, Offset)?>(null);
  bool _selDrag = false;

  @override
  void initState() {
    super.initState();
    _ctl.setBrush(widget.session.brush);
    widget.session.addListener(_syncBrush);
    widget.session.registerLayer(this);
    _sub = _ctl.events.listen(_onEvent);
  }

  @override
  void didUpdateWidget(PdfPageInkLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session || oldWidget.page != widget.page) {
      oldWidget.session.removeListener(_syncBrush);
      oldWidget.session.unregisterLayer(this, page: oldWidget.page);
      widget.session.addListener(_syncBrush);
      widget.session.registerLayer(this);
      _pen = widget.session.penFor(widget.page);
      _ctl.setBrush(widget.session.brush);
    }
  }

  @override
  void dispose() {
    if (_erasing) {
      _commitErase();
      widget.session.setErasing(false);
    }
    widget.session.removeListener(_syncBrush);
    widget.session.unregisterLayer(this, page: widget.page);
    _sub?.cancel();
    _ctl.dispose();
    _sel.dispose();
    super.dispose();
  }

  int get page => widget.page;

  void _syncBrush() => _ctl.setBrush(widget.session.brush);

  // --- işaretçi girişi (PdfInkInput çağırır) ---

  RenderBox? get _box {
    final o = context.findRenderObject();
    return o is RenderBox && o.attached && o.hasSize ? o : null;
  }

  /// [global] noktası bu sayfanın dikdörtgeninde mi?
  bool containsGlobal(Offset global) {
    final b = _box;
    if (b == null) return false;
    return (Offset.zero & b.size).contains(b.globalToLocal(global));
  }

  InkPoint _point(PointerEvent e) {
    final l = _box!.globalToLocal(e.position);
    return InkPoint(
      x: l.dx,
      y: l.dy,
      pressure: e.pressureMax > e.pressureMin
          ? ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
                .clamp(0.0, 1.0)
          : 0.5,
      tilt: e.tilt,
      tMs: e.timeStamp.inMicroseconds / 1000,
    );
  }

  void pointerDown(PointerDownEvent e) {
    if (_pointer != null || _box == null) return;
    _pointer = e.pointer;
    if (widget.session.selecting) {
      _selDrag = true;
      final l = _box!.globalToLocal(e.position);
      _sel.value = (l, l);
      return;
    }
    _last = _point(e);
    _ctl.beginStroke(
      _last!,
      eraser: e.kind == PointerDeviceKind.invertedStylus,
    );
  }

  void pointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || _box == null) return;
    if (_selDrag) {
      final s = _sel.value;
      if (s != null) _sel.value = (s.$1, _box!.globalToLocal(e.position));
      return;
    }
    _last = _point(e);
    _ctl.addPoint(_last!);
  }

  void pointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_selDrag) {
      _selDrag = false;
      final s = _sel.value;
      _sel.value = null;
      final c = _coords;
      if (s == null || c == null || _box == null) return;
      final a = c.toPage(s.$1), b = c.toPage(_box!.globalToLocal(e.position));
      widget.session.onSelectBox?.call(widget.page, a.dx, a.dy, b.dx, b.dy, widget.pageWidth, widget.pageHeight);
      return;
    }
    _ctl.endStroke(_box == null ? _last! : _point(e));
  }

  void pointerCancel(PointerCancelEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_selDrag) {
      _selDrag = false;
      _sel.value = null;
      return;
    }
    _ctl.cancelStroke();
  }

  // --- silgi ---

  double _eraseRadiusPage(InkBrush b) =>
      math.max(8.0, b.width * 2) * (_coords?.pageUnitsPerViewPx ?? 1);

  void _eraseAt(InkPoint p) {
    final c = _coords;
    final brush = _ctl.liveBrush;
    if (c == null || brush == null) return;
    final o = c.toPage(Offset(p.x, p.y));
    _erased.addAll(
      widget.session.eraseAt(widget.page, o.dx, o.dy, _eraseRadiusPage(brush)),
    );
  }

  void _commitErase() {
    if (_erased.isEmpty) return;
    widget.session.commitErase(widget.page, List.of(_erased));
    _erased.clear();
  }

  // Olaylar mikro görev sonrası gelir; denetleyici bu sırada henüz bir sonraki
  // çizgiye geçmemiştir (işaretçi olayları arasında mikro görevler çalışır).
  void _onEvent(InkEvent e) {
    final c = _coords;
    switch (e) {
      case InkStrokeStart():
        _erasing = _ctl.liveBrush?.tool == InkTool.eraser;
        _erased.clear();
        widget.session.setErasing(_erasing);
        if (_erasing) _eraseAt(e.point);
      case InkStrokePoint():
        if (_erasing) _eraseAt(e.point);
      case InkStrokeEnd():
        if (_erasing) {
          _commitErase();
          _erasing = false;
          widget.session.setErasing(false);
          return;
        }
        final idx = _ctl.finished.indexWhere((f) => f.id == e.strokeId);
        if (idx < 0 || c == null) return;
        final f = _ctl.finished[idx];
        widget.session.addStroke(widget.page, f.brush, f.points, c);
        _ctl.clear(); // görüntü artık sayfa katmanında
      case InkStrokeCancel():
        if (_erasing) {
          _commitErase();
          _erasing = false;
          widget.session.setErasing(false);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          _coords = PageCoords.tryCreate(
            pageWidth: widget.pageWidth,
            pageHeight: widget.pageHeight,
            viewWidth: box.maxWidth,
            viewHeight: box.maxHeight,
          );
          final coords = _coords;
          if (coords == null) return const SizedBox.shrink();
          return Stack(
            fit: StackFit.expand,
            children: [
              // Kayıtlı çizgiler: yalnız sayfa çizgileri değişince ya da boyut değişince boyanır.
              RepaintBoundary(
                child: CustomPaint(
                  painter: _SavedPainter(_pen, coords),
                  size: Size.infinite,
                ),
              ),
              // Süren çizgi: küçük ve ayrı katman.
              RepaintBoundary(
                child: CustomPaint(
                  painter: _LivePainter(_ctl),
                  size: Size.infinite,
                ),
              ),
              // "Soru seç" sürüklemesi: görünür çerçeve.
              ValueListenableBuilder<(Offset, Offset)?>(
                valueListenable: _sel,
                builder: (_, s, _) => s == null
                    ? const SizedBox.shrink()
                    : CustomPaint(
                        key: const Key('pdf-select-drag'),
                        painter: PdfBoxPainter([Rect.fromPoints(s.$1, s.$2)], const Color(0xFF1565C0)),
                        size: Size.infinite,
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SavedPainter extends CustomPainter {
  _SavedPainter(this.pen, this.coords) : super(repaint: pen);
  final PagePen pen;
  final PageCoords coords;

  @override
  void paint(Canvas canvas, Size size) => pen.paint(
    canvas,
    coords.viewWidth / coords.pageWidth,
    coords.viewHeight / coords.pageHeight,
  );

  @override
  bool shouldRepaint(_SavedPainter old) =>
      old.pen != pen ||
      old.coords.viewWidth != coords.viewWidth ||
      old.coords.viewHeight != coords.viewHeight;
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.c) : super(repaint: c);
  final InkBController c;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in c.liveChunks) {
      canvas.drawPicture(p);
    }
    final live = c.livePath();
    if (live != null) canvas.drawPath(live, inkPaintFor(c.liveBrush!));
  }

  @override
  bool shouldRepaint(_LivePainter old) => old.c != c;
}

/// Görünüm piksellerinde dikdörtgen çerçeveler (seçim sürüklemesi, işaretli kutular).
class PdfBoxPainter extends CustomPainter {
  PdfBoxPainter(this.rects, this.color);
  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withAlpha(36);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final r in rects) {
      canvas.drawRect(r, fill);
      canvas.drawRect(r, line);
    }
  }

  @override
  bool shouldRepaint(PdfBoxPainter old) => old.color != color || !listEquals(old.rects, rects);
}
