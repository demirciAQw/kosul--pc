import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ink/data/ink_outline.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../ink/domain/pen_profiles.dart';
import '../../pdf/pdf_providers.dart';
import '../domain/ink_notebook.dart';
import '../domain/page_size.dart';
import 'page_template_painter.dart';

/// Küçük resim: şablon + sayfanın çizgileri. Çizgiler akışta TEK abonelikle izlenir
/// (State'te), sonuç bir kez `ui.Picture`'a kaydedilir (yeniden boyamada outline hesabı yok);
/// ardışık güncellemeler [PageThumbState.delay] ile geciktirilir.
class PageThumb extends ConsumerStatefulWidget {
  const PageThumb({super.key, required this.page});
  final InkNotePageRecord page;

  @override
  ConsumerState<PageThumb> createState() => PageThumbState();
}

class PageThumbState extends ConsumerState<PageThumb> {
  /// Peş peşe çizgi değişikliklerinde yeniden çözme/çizme bekleme süresi.
  static const delay = Duration(milliseconds: 400);

  StreamSubscription<List<InkStroke>>? _sub;
  Timer? _timer;
  List<InkStroke>? _pending;
  bool _first = true;
  ui.Picture? _picture;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _sub?.cancel();
    _timer?.cancel();
    _first = true;
    _pending = null;
    final p = widget.page;
    _sub = ref
        .read(inkStrokeRepositoryProvider)
        .watchPage(
          NotePageOwner(p.id, p.pageNo),
          attemptNo: 0,
          layer: 0,
          noQuestion: true,
        )
        .listen(_onData);
  }

  void _onData(List<InkStroke> strokes) {
    if (_first) {
      _first = false;
      _apply(strokes);
      return;
    }
    _pending = strokes;
    _timer ??= Timer(delay, () {
      _timer = null;
      final d = _pending;
      _pending = null;
      if (d != null && mounted) _apply(d);
    });
  }

  void _apply(List<InkStroke> strokes) {
    final old = _picture;
    _picture = _record(strokes);
    setState(() {});
    old?.dispose();
  }

  ui.Picture _record(List<InkStroke> strokes) {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (final s in strokes) {
      final t = parseToolColumn(s.tool);
      final kind = penProfiles.keys.where((k) => k.name == t.name).firstOrNull;
      final brush = InkBrush(
        tool: kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
        color: s.color,
        width: s.width,
        kind: kind,
        hardness: t.hardness,
      );
      final pts = [
        for (final p in s.points)
          InkPoint(
            x: p.x,
            y: p.y,
            pressure: p.pressure,
            tilt: p.tilt,
            tMs: p.t.toDouble(),
          ),
      ];
      c.drawPath(
        inkOutlinePath(pts, brush, complete: true),
        inkPaintFor(brush),
      );
    }
    return rec.endRecording();
  }

  @override
  void didUpdateWidget(PageThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.id != widget.page.id ||
        oldWidget.page.pageNo != widget.page.pageNo) {
      _listen();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _picture?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: PageThumbPainter(widget.page, _picture),
      size: Size.infinite,
    ),
  );
}

class PageThumbPainter extends CustomPainter {
  PageThumbPainter(this.page, this.strokes);
  final InkNotePageRecord page;
  final ui.Picture? strokes;

  @override
  void paint(Canvas canvas, Size size) {
    // Sonsuz sayfada küçük resim yalnız üst A4 kadarını gösterir.
    final inf = isInfinitePage(page.height);
    final shownH = inf ? a4PageHeight : page.height;
    PageTemplatePainter(
      template: page.template,
      background: page.background,
      pageWidth: page.width,
      pageHeight: shownH,
      infinite: inf,
    ).paint(canvas, size);
    final pic = strokes;
    if (pic == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / page.width, size.height / shownH);
    canvas.drawPicture(pic);
    canvas.restore();
  }

  @override
  bool shouldRepaint(PageThumbPainter old) =>
      old.page != page || !identical(old.strokes, strokes);
}
