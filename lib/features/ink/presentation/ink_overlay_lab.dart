import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../pdf/presentation/pdf_ink_overlay.dart'
    show globalVisibleRect, waitDrawnFrames;
import '../data/ink_b_controller.dart';
import '../data/ink_overlay_codec.dart';
import '../data/ink_overlay_host.dart';
import '../data/ink_surface_b.dart';
import '../domain/ink_models.dart';
import '../domain/ink_overlay_geometry.dart';

/// Kalem denemesi "Ink katmanı" kipi: B yüzeyi (Flutter) altta, Ink'in yerel ıslak çizgisi üstte.
/// Kalem çizgisini yerel katman çizer; kalkınca noktalar B denetleyicisine aktarılır (kuru
/// çizim), çizim karesi bitince ıslak çizgi bırakılır. Katman yoksa B yüzeyi kendisi çizer.
/// Bu kipte yakınlaştırma yok (yalnız ıslak -> kuru geçişi ve gecikmeyi kıyaslamak için).
class InkOverlayLabSurface extends StatefulWidget {
  const InkOverlayLabSurface({
    super.key,
    required this.controller,
    required this.brush,
  });

  final InkBController controller;
  final InkBrush brush;

  @override
  State<InkOverlayLabSurface> createState() => _InkOverlayLabSurfaceState();
}

class _InkOverlayLabSurfaceState extends State<InkOverlayLabSurface> {
  final _key = GlobalKey();
  StreamSubscription<InkOverlayEvent>? _sub;
  bool _alive = true;
  Rect? _regionPx;

  @override
  void initState() {
    super.initState();
    final host = InkOverlayHost.instance;
    host.claim(this);
    host.availability.addListener(_sync);
    host.ownership.addListener(_sync);
    _sync();
    _frame();
  }

  @override
  void didUpdateWidget(InkOverlayLabSurface old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _alive = false;
    final host = InkOverlayHost.instance;
    host.availability.removeListener(_sync);
    host.ownership.removeListener(_sync);
    _sub?.cancel();
    host.release(this);
    super.dispose();
  }

  void _sync() {
    final host = InkOverlayHost.instance;
    final c = host.controller;
    if (c == null || !host.isOwner(this) || !c.available) return;
    _sub ??= c.events.listen(_onEvent);
    final b = overlayBrushFor(
      widget.brush,
      MediaQuery.devicePixelRatioOf(context),
    );
    if (b == null) {
      c.setMode(InkOverlayMode.off);
    } else {
      c.setBrush(family: b.family, argb: b.argb, sizePx: b.sizePx);
      c.setMode(b.mode);
    }
  }

  void _frame() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_alive) return;
      final host = InkOverlayHost.instance;
      final c = host.controller;
      final box = _key.currentContext?.findRenderObject();
      if (c != null && c.available && host.isOwner(this) && box is RenderBox) {
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final r = globalVisibleRect(box);
        _regionPx = r == null
            ? null
            : Rect.fromLTRB(
                r.left * dpr,
                r.top * dpr,
                r.right * dpr,
                r.bottom * dpr,
              );
        final rp = _regionPx;
        c.setRegions(rp == null ? const [] : [rp]);
      }
      _frame();
    });
  }

  Future<void> _onEvent(InkOverlayEvent e) async {
    if (e is! OverlayStrokeFinished) return;
    final box = _key.currentContext?.findRenderObject();
    if (box is RenderBox && e.points.isNotEmpty) {
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final pts = overlayPointsToView(
        e.points,
        dpr: dpr,
        layerOriginLogical: box.localToGlobal(Offset.zero),
      );
      final c = widget.controller;
      c.beginStroke(pts.first);
      for (final p in pts.skip(1)) {
        c.addPoint(p);
      }
      c.endStroke(pts.last);
    }
    await waitDrawnFrames();
    if (_alive) InkOverlayHost.instance.controller?.releaseStrokes([e.id]);
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _key,
    child: InkSurfaceBView(controller: widget.controller),
  );
}
