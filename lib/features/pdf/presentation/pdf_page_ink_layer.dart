import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ink/data/ink_b_controller.dart';
import '../../ink/data/ink_outline.dart';
import '../../ink/domain/hold_detector.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_object.dart' show InkRect;
import '../../ink/domain/lasso_gesture.dart';
import '../../ink/domain/shape_recognizer.dart';
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
    this.originX = 0,
    this.originY = 0,
  });

  final PdfInkSession session;

  /// 0'dan.
  final int page;

  /// Sayfa boyutu, PDF birimi, döndürme uygulanmış.
  final double pageWidth;
  final double pageHeight;

  /// Çözüm ekranı: katman yalnız sayfanın bir bölgesini kaplar. [pageWidth] /
  /// [pageHeight] bölgenin boyutu, [originX]/[originY] bölgenin sayfadaki sol-üstü.
  final double originX;
  final double originY;

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

  // --- kement: yol (görünüm yerel noktaları) ve tutamak sürüklemesi ---
  final _lassoPath = ValueNotifier<List<Offset>>(const []);
  bool _lassoDraw = false;
  LassoDrag? _lassoDrag;

  // --- şekil düzeltme: basılı tutma ---
  late HoldDetector _hold = HoldDetector(holdMs: widget.session.holdMs, tolerance: widget.session.holdTolerancePx);
  Timer? _holdTimer;
  final List<InkPoint> _raw = [];

  /// [_raw] içinde çapanın (son gerçek hareket noktasının) sırası: sonrasındaki
  /// kalem titremesi tanımaya girmez (yol uzunluğunu şişirip çizgiyi bozar).
  int _anchorIdx = 0;
  final _shape = ValueNotifier<List<InkPoint>?>(null);
  InkBrush? _shapeBrush;
  Timer? _settleTimer;
  bool _settling = false;

  // --- doğrudan şekil aracı: sürükle, bırakınca mükemmel şekil ---
  bool _shapeDrag = false;
  InkPoint? _shapeP0;

  // --- silgi imleci (hover / değme): görünüm yerel noktası ---
  final _cursor = ValueNotifier<Offset?>(null);
  Timer? _cursorTimer;

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
    _holdTimer?.cancel();
    _settleTimer?.cancel();
    _cursorTimer?.cancel();
    _cursor.dispose();
    _sub?.cancel();
    _ctl.dispose();
    _sel.dispose();
    _lassoPath.dispose();
    _shape.dispose();
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
      // Baskı olmayan aygıtta (fare/parmak) sabit 0.5, sertlikle eğilmez.
      pressure: e.pressureMax > e.pressureMin
          ? widget.session.shapePressure(
              ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin)).clamp(0.0, 1.0),
            )
          : 0.5,
      tilt: e.tilt,
      tMs: e.timeStamp.inMicroseconds / 1000,
    );
  }

  /// Silgi seçiliyken kalem havada ya da değerken yarıçap dairesini gösterir
  /// (olay kesilince [_cursorTimer] ile söner; hover çıkış olayı yoktur).
  void _showCursor(Offset local) {
    final s = widget.session;
    if (s.brush.tool != InkTool.eraser || s.lassoMode || s.selecting) return;
    _cursor.value = local;
    _cursorTimer?.cancel();
    _cursorTimer = Timer(const Duration(milliseconds: 500), () => _cursor.value = null);
  }

  /// Kalem havada (PdfInkInput çağırır).
  void pointerHover(PointerHoverEvent e) {
    if (_box == null) return;
    _showCursor(_box!.globalToLocal(e.position));
  }

  double get _eraseViewRadius => math.max(8.0, widget.session.brush.width * 2);

  void pointerDown(PointerDownEvent e) {
    if (_pointer != null || _box == null) return;
    if (widget.session.lassoMode) {
      _lassoDown(e);
      return;
    }
    _showCursor(_box!.globalToLocal(e.position));
    final tool = widget.session.shapeTool;
    if (tool != null &&
        !widget.session.selecting &&
        widget.session.brush.tool != InkTool.eraser &&
        e.kind != PointerDeviceKind.invertedStylus) {
      _pointer = e.pointer;
      _shapeDrag = true;
      _shapeP0 = _shapePoint(e);
      _shapeBrush = widget.session.brush;
      _last = _shapeP0;
      return;
    }
    _pointer = e.pointer;
    if (widget.session.selecting) {
      _selDrag = true;
      final l = _box!.globalToLocal(e.position);
      _sel.value = (l, l);
      return;
    }
    _last = _point(e);
    _ctl.beginStroke(_last!, eraser: e.kind == PointerDeviceKind.invertedStylus);
    _holdStart(e.kind == PointerDeviceKind.invertedStylus);
  }

  // --- doğrudan şekil aracı ---

  /// Şekil noktası: baskı sabit 0.5 (şekil kalınlığı kalemin baskısına bağlı olmasın).
  InkPoint _shapePoint(PointerEvent e) {
    final l = _box!.globalToLocal(e.position);
    return InkPoint(x: l.dx, y: l.dy, tMs: e.timeStamp.inMicroseconds / 1000);
  }

  List<InkPoint> _stamped(List<InkPoint> pts, double t0, double t1) {
    final n = pts.length;
    return [
      for (var i = 0; i < n; i++)
        InkPoint(
          x: pts[i].x,
          y: pts[i].y,
          pressure: pts[i].pressure,
          tilt: pts[i].tilt,
          tMs: n < 2 ? t0 : t0 + (t1 - t0) * i / (n - 1),
        ),
    ];
  }

  void _shapeMove(PointerEvent e) {
    final p0 = _shapeP0, tool = widget.session.shapeTool;
    if (p0 == null || tool == null) return;
    _last = _shapePoint(e);
    final pts = buildShape(tool, p0, _last!);
    _shape.value = pts.isEmpty ? null : _stamped(pts, p0.tMs, _last!.tMs);
  }

  void _shapeUp(PointerEvent e) {
    final p0 = _shapeP0, tool = widget.session.shapeTool, b = _shapeBrush, c = _coords;
    _shapeDrag = false;
    _shapeP0 = null;
    if (p0 == null || tool == null || b == null || c == null) {
      _shape.value = null;
      return;
    }
    final p1 = _shapePoint(e);
    final pts = buildShape(tool, p0, p1);
    _shape.value = null;
    // Dokunuş/titreme şekil sayılmaz.
    if (pts.isEmpty || (p1.x - p0.x).abs() + (p1.y - p0.y).abs() < 6) return;
    widget.session.addStroke(widget.page, b, _stamped(pts, p0.tMs, p1.tMs), c);
  }

  // --- şekil düzeltme ---

  void _holdStop() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _settling = false;
  }

  void _holdStart(bool inverted) {
    _holdStop();
    _raw.clear();
    _shape.value = null;
    final b = _ctl.liveBrush;
    if (!widget.session.shapeSnap || inverted || b == null || b.tool == InkTool.eraser) return;
    _hold = HoldDetector(holdMs: widget.session.holdMs, tolerance: widget.session.holdTolerancePx);
    _raw.add(_last!);
    _anchorIdx = 0;
    _hold.start(_last!.x, _last!.y, 0);
    _armHold();
    // Çizginin ilk 150 ms'sinde hareket zamanlayıcıyı sıfırlamaz (çapa noktayı izler).
    _settling = true;
    _settleTimer = Timer(const Duration(milliseconds: shapeHoldSettleMs), () => _settling = false);
  }

  void _armHold() {
    _holdTimer?.cancel();
    _holdTimer = Timer(Duration(milliseconds: widget.session.holdMs), _onHold);
  }

  /// Kalem [PdfInkSession.holdMs] hareketsiz kaldı: tanınırsa çizgi düzeltilmiş şekle döner
  /// (önizleme; kalem kalkınca şekil kaydedilir), tanınmazsa serbest çizgi aynen sürer.
  void _onHold() {
    if (_pointer == null || _shape.value != null || _selDrag) return;
    final brush = _ctl.liveBrush;
    if (brush == null || !widget.session.shapeSnap || _raw.length < 5) return;
    final r = recognizeShape(_raw.sublist(0, _anchorIdx + 1));
    if (r == null) return;
    _shapeBrush = brush;
    _shape.value = _stamped(r.points, _raw.first.tMs, _raw.last.tMs);
    _ctl.cancelStroke(); // serbest çizgi önizlemeden kalkar; kaydedilmez
  }

  // --- kement ---

  bool _isLassoPointer(int pointer) => pointer == _pointer && (_lassoDraw || _lassoDrag != null);

  void _lassoDown(PointerDownEvent e) {
    final s = widget.session, c = _coords;
    if (c == null || s.selectionBusy) return;
    _pointer = e.pointer;
    final l = _box!.globalToLocal(e.position);
    final o = c.toPage(l);
    final b = s.hasSelection && s.selectionPage == widget.page ? s.selectionBoundsSaved : null;
    if (b != null) {
      final u = c.pageUnitsPerViewPx;
      final h = hitLassoHandle(b, o.dx, o.dy, tol: 16 * u, rotateOffset: 32 * u);
      if (h != null) {
        _lassoDrag = LassoDrag(
          h,
          b,
          o.dx,
          o.dy,
          pageBounds: InkRect(c.originX, c.originY, c.originX + c.pageWidth, c.originY + c.pageHeight),
        );
        return;
      }
    }
    s.clearSelection();
    _lassoDraw = true;
    _lassoPath.value = [l];
  }

  void _lassoMove(PointerMoveEvent e) {
    final c = _coords;
    if (c == null) return;
    final l = _box!.globalToLocal(e.position);
    final d = _lassoDrag;
    if (d != null) {
      final o = c.toPage(l);
      widget.session.previewSelection(d.apply(widget.session.selectionOriginals, o.dx, o.dy));
    } else if (_lassoDraw) {
      _lassoPath.value = [..._lassoPath.value, l];
    }
  }

  void _lassoUp() {
    final s = widget.session;
    if (_lassoDrag != null) {
      _lassoDrag = null;
      unawaited(s.commitSelectionTransform());
    } else if (_lassoDraw) {
      _lassoDraw = false;
      final c = _coords;
      final path = _lassoPath.value;
      _lassoPath.value = const [];
      if (c == null) return;
      s.selectLasso(widget.page, [
        for (final v in path)
          () {
            final o = c.toPage(v);
            return InkPoint(x: o.dx, y: o.dy);
          }(),
      ]);
    }
  }

  void pointerMove(PointerMoveEvent e) {
    if (e.pointer != _pointer || _box == null) return;
    if (_isLassoPointer(e.pointer)) {
      _lassoMove(e);
      return;
    }
    if (_selDrag) {
      final s = _sel.value;
      if (s != null) _sel.value = (s.$1, _box!.globalToLocal(e.position));
      return;
    }
    if (_shapeDrag) {
      _shapeMove(e);
      return;
    }
    _showCursor(_box!.globalToLocal(e.position));
    _last = _point(e);
    if (_shape.value != null) return; // şekil sabitlendi; kalem kalkana dek bekler
    _ctl.addPoint(_last!);
    if (_holdTimer != null) {
      _raw.add(_last!);
      if (_hold.onPoint(_last!.x, _last!.y, 0)) {
        _anchorIdx = _raw.length - 1;
        if (!_settling) _armHold();
      }
    }
  }

  void pointerUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (_lassoDraw || _lassoDrag != null) {
      _lassoUp();
      return;
    }
    _holdStop();
    if (_shapeDrag) {
      _shapeUp(e);
      return;
    }
    final shape = _shape.value;
    if (shape != null) {
      _shape.value = null;
      final c = _coords, b = _shapeBrush;
      if (c != null && b != null) widget.session.addStroke(widget.page, b, shape, c);
      return;
    }
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
    if (_lassoDrag != null) {
      _lassoDrag = null;
      widget.session.cancelSelectionTransform();
      return;
    }
    if (_lassoDraw) {
      _lassoDraw = false;
      _lassoPath.value = const [];
      return;
    }
    _holdStop();
    _shape.value = null;
    if (_shapeDrag) {
      _shapeDrag = false;
      _shapeP0 = null;
      return;
    }
    if (_selDrag) {
      _selDrag = false;
      _sel.value = null;
      return;
    }
    _ctl.cancelStroke();
  }

  // --- silgi ---

  /// Silgi yarıçapı (sayfa birimi): fırça kalınlığının iki katı (en az 8 görünüm pikseli).
  /// Defter araç çubuğu `width = yarıçap / 2` verir.
  double _eraseRadiusPage(InkBrush b) => math.max(8.0, b.width * 2) * (_coords?.pageUnitsPerViewPx ?? 1);

  Offset? _lastErase;

  void _eraseAt(InkPoint p) {
    final c = _coords;
    final brush = _ctl.liveBrush;
    if (c == null || brush == null) return;
    final o = c.toPage(Offset(p.x, p.y));
    _erased.addAll(
      widget.session.eraseAt(
        widget.page,
        o.dx,
        o.dy,
        _eraseRadiusPage(brush),
        prevX: _lastErase?.dx,
        prevY: _lastErase?.dy,
      ),
    );
    _lastErase = o;
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
        _lastErase = null;
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
            originX: widget.originX,
            originY: widget.originY,
          );
          final coords = _coords;
          if (coords == null) return const SizedBox.shrink();
          return Stack(
            fit: StackFit.expand,
            children: [
              // Kayıtlı çizgiler: yalnız sayfa çizgileri değişince ya da boyut değişince boyanır.
              RepaintBoundary(
                child: CustomPaint(painter: _SavedPainter(_pen, coords), size: Size.infinite),
              ),
              // Süren çizgi: küçük ve ayrı katman.
              RepaintBoundary(
                child: CustomPaint(painter: _LivePainter(_ctl), size: Size.infinite),
              ),
              // Şekil düzeltme önizlemesi.
              ValueListenableBuilder<List<InkPoint>?>(
                valueListenable: _shape,
                builder: (_, pts, _) => pts == null || _shapeBrush == null
                    ? const SizedBox.shrink()
                    : RepaintBoundary(
                        child: CustomPaint(
                          key: const Key('ink-shape-preview'),
                          painter: _ShapePainter(pts, _shapeBrush!),
                          size: Size.infinite,
                        ),
                      ),
              ),
              // Silgi imleci: yarıçap dairesi.
              CustomPaint(
                key: const Key('ink-eraser-cursor'),
                painter: _CursorPainter(_cursor, () => _eraseViewRadius),
                size: Size.infinite,
              ),
              // Kement yolu ve seçim çerçevesi (8 tutamak + döndürme).
              CustomPaint(
                key: const Key('ink-lasso-overlay'),
                painter: _LassoPainter(widget.session, widget.page, coords, _lassoPath),
                size: Size.infinite,
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

class _CursorPainter extends CustomPainter {
  _CursorPainter(this.pos, this.radius) : super(repaint: pos);
  final ValueListenable<Offset?> pos;
  final double Function() radius;

  @override
  void paint(Canvas canvas, Size size) {
    final c = pos.value;
    if (c == null) return;
    final r = radius();
    canvas.drawCircle(c, r, Paint()..color = const Color(0x22000000));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0xFF455A64)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.pos != pos;
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.points, this.brush);
  final List<InkPoint> points;
  final InkBrush brush;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawPath(inkOutlinePath(points, brush, complete: true), inkPaintFor(brush));

  @override
  bool shouldRepaint(_ShapePainter old) => old.points != points || old.brush != brush;
}

/// Kement yolu (kesikli) ve seçimin sınır kutusu: 8 tutamak ve üstte döndürme tutamacı.
class _LassoPainter extends CustomPainter {
  _LassoPainter(this.session, this.page, this.coords, this.path)
    : super(repaint: Listenable.merge([session.selectionTick, path]));
  final PdfInkSession session;
  final int page;
  final PageCoords coords;
  final ValueListenable<List<Offset>> path;

  @override
  void paint(Canvas canvas, Size size) {
    const blue = Color(0xFF1565C0);
    final line = Paint()
      ..color = blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final pts = path.value;
    if (pts.length > 1) {
      final p = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final o in pts.skip(1)) {
        p.lineTo(o.dx, o.dy);
      }
      p.close();
      canvas.drawPath(p, Paint()..color = blue.withAlpha(24));
      canvas.drawPath(p, line);
    }
    if (!session.hasSelection || session.selectionPage != page) return;
    final b = session.selectionBoundsNow;
    if (b == null) return;
    final tl = coords.toView(Offset(b.left, b.top)), br = coords.toView(Offset(b.right, b.bottom));
    final r = Rect.fromPoints(tl, br);
    canvas.drawRect(r, Paint()..color = blue.withAlpha(20));
    canvas.drawRect(r, line);
    final fill = Paint()..color = Colors.white;
    for (final h in LassoHandle.values) {
      if (h == LassoHandle.body || !isHandleUsable(b, h, tol: 16 * coords.pageUnitsPerViewPx)) continue;
      final pos = handlePosition(b, h, rotateOffset: 32 * coords.pageUnitsPerViewPx);
      final c = coords.toView(Offset(pos.x, pos.y));
      if (h == LassoHandle.rotate) {
        canvas.drawLine(coords.toView(Offset(b.centerX, b.top)), c, line);
        canvas.drawCircle(c, 7, fill);
        canvas.drawCircle(c, 7, line);
      } else {
        final hr = Rect.fromCenter(center: c, width: 10, height: 10);
        canvas.drawRect(hr, fill);
        canvas.drawRect(hr, line);
      }
    }
  }

  @override
  bool shouldRepaint(_LassoPainter old) => old.session != session || old.page != page || old.coords != coords;
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
    originX: coords.originX,
    originY: coords.originY,
  );

  @override
  bool shouldRepaint(_SavedPainter old) =>
      old.pen != pen ||
      old.coords.originX != coords.originX ||
      old.coords.originY != coords.originY ||
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
