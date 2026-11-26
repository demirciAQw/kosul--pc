import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../domain/ink_latency.dart';
import '../domain/ink_models.dart';
import 'ink_b_controller.dart';
import 'ink_outline.dart';

/// Bu işaretçi türü çizer mi? Kalem her zaman; fare yalnızca [stylusOnly]
/// kapalıyken (masaüstü denemesi). Parmak ve diğerleri ASLA çizmez: parmak
/// kaydırır/yakınlaştırır, avuç yok sayılır.
bool inkPointerDraws(PointerDeviceKind kind, {required bool stylusOnly}) {
  return switch (kind) {
    PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => true,
    PointerDeviceKind.mouse => !stylusOnly,
    _ => false,
  };
}

/// B uygulaması: saf Flutter çizim yüzeyi.
///
/// Ters kalem ucu (invertedStylus) silgi gibi davranır (A'daki silgi
/// davranışına denk; seçili fırça ne olursa olsun siler).
///
/// Gecikme ölçümü: `PointerEvent.timeStamp` (motor saati) ile
/// `FrameTiming` aynı tek yönlü saati kullanır (Android'de CLOCK_MONOTONIC).
/// İki ölçüm yazılır:
/// - "KocumInk B giris->raster ms=": rasterFinish'e kadar (ekrana sunuma çok
///   yakın üst sınır; gerçek foton gecikmesi değil).
/// - "KocumInk B giris->vsync ms=": karenin vsync'ine kadar. Yerel A tarafı
///   ("A giris->vsync ms=") yalnız vsync'e kadar ölçtüğünden eşit
///   karşılaştırma bu ikisi arasındadır; raster ölçümü B'ye ek yük (build +
///   raster süresi) katar ve A ile doğrudan kıyaslanmamalıdır.
class InkSurfaceBView extends StatefulWidget {
  const InkSurfaceBView({
    super.key,
    required this.controller,
    this.onLatency = _printRaster,
    this.onVsyncLatency = _printVsync,
  });

  final InkBController controller;

  /// Bir karede görünen girişlerin en kötü giris->raster gecikmesi, ms.
  final void Function(double worstMs, int inputs) onLatency;

  /// Bir karede görünen girişlerin en kötü giris->vsync gecikmesi, ms.
  final void Function(double worstMs, int inputs) onVsyncLatency;

  static void _printRaster(double worstMs, int inputs) {
    // ignore: avoid_print
    print('KocumInk B giris->raster ms=${worstMs.toStringAsFixed(1)} n=$inputs');
  }

  static void _printVsync(double worstMs, int inputs) {
    // ignore: avoid_print
    print('KocumInk B giris->vsync ms=${worstMs.toStringAsFixed(1)} n=$inputs');
  }

  @override
  State<InkSurfaceBView> createState() => InkSurfaceBViewState();
}

class InkSurfaceBViewState extends State<InkSurfaceBView> {
  final _latency = InkLatencyTracker();
  int? _activePointer;
  PointerDeviceKind? _activeKind;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(handleTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(handleTimings);
    super.dispose();
  }

  @visibleForTesting
  void handleTimings(List<ui.FrameTiming> timings) {
    for (final t in timings) {
      final r = _latency.onFrameDetailed(
        buildStartUs: t.timestampInMicroseconds(ui.FramePhase.buildStart),
        rasterFinishUs: t.timestampInMicroseconds(ui.FramePhase.rasterFinish),
        vsyncUs: t.timestampInMicroseconds(ui.FramePhase.vsyncStart),
      );
      if (r.raster.isNotEmpty) {
        widget.onLatency(r.raster.reduce(math.max), r.raster.length);
        widget.onVsyncLatency(r.vsync.reduce(math.max), r.vsync.length);
      }
    }
  }

  InkPoint _point(PointerEvent e) => InkPoint(
    x: e.localPosition.dx,
    y: e.localPosition.dy,
    pressure: e.pressureMax > e.pressureMin
        ? ((e.pressure - e.pressureMin) / (e.pressureMax - e.pressureMin))
              .clamp(0.0, 1.0)
        : 0.5,
    tilt: e.tilt,
    tMs: e.timeStamp.inMicroseconds / 1000,
  );

  void _down(PointerDownEvent e) {
    if (_activePointer != null) return; // tek çizen işaretçi
    if (!inkPointerDraws(e.kind, stylusOnly: widget.controller.stylusOnly)) {
      return;
    }
    _activePointer = e.pointer;
    _activeKind = e.kind;
    _latency.onInput(e.timeStamp.inMicroseconds);
    widget.controller.beginStroke(
      _point(e),
      pressureFromDevice: e.kind != PointerDeviceKind.mouse,
      eraser: e.kind == PointerDeviceKind.invertedStylus,
    );
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    _latency.onInput(e.timeStamp.inMicroseconds);
    widget.controller.addPoint(_point(e));
  }

  void _cancel(PointerCancelEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    // Kalem iptali (avuç değince ACTION_CANCEL) çizgiyi bitirir; parmak/fare atar.
    final pen = e.kind == PointerDeviceKind.stylus || e.kind == PointerDeviceKind.invertedStylus;
    _activeKind = null;
    widget.controller.cancelStroke(keep: pen);
  }

  void _up(PointerEvent e) {
    if (e.pointer != _activePointer) return;
    _activePointer = null;
    _activeKind = null;
    widget.controller.endStroke(_point(e));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Biten çizgiler: yalnız liste değişince boyanır (süren çizgi
          // her harekette bunları yeniden çizmez).
          RepaintBoundary(
            child: CustomPaint(
              painter: _FinishedPainter(widget.controller),
              size: Size.infinite,
            ),
          ),
          // Süren çizgi: her harekette boyanır, küçük ve ayrı katman.
          RepaintBoundary(
            child: CustomPaint(
              painter: _LivePainter(widget.controller),
              size: Size.infinite,
            ),
          ),
        ],
      ),
    );
  }

  @visibleForTesting
  PointerDeviceKind? get activeKind => _activeKind;
}

class _FinishedPainter extends CustomPainter {
  _FinishedPainter(this.c) : super(repaint: c.finishedChanges);
  final InkBController c;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in c.finished) {
      canvas.drawPicture(f.picture); // önbellekten: yeniden hesap yok
    }
  }

  @override
  bool shouldRepaint(_FinishedPainter old) => old.c != c;
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
