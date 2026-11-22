import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../ink/data/ink_outline.dart';
import '../../ink/data/ink_stroke_repository.dart';
import '../../ink/domain/ink_geometry.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../ink/domain/stroke_codec.dart';
import '../domain/ink_history.dart';
import '../domain/page_coords.dart';
import 'pdf_page_ink_layer.dart';

/// Sayfada duran bir çizgi. Noktalar ve kalınlık SAYFA biriminde; [id] kayıt
/// bitene kadar null (iyimser ekleme).
class PenStroke {
  PenStroke(this.brush, this.points, {this.id});
  String? id;
  final InkBrush brush;
  final List<InkPoint> points;
  ui.Picture? _picture;

  /// Çizgi resmi bir kez kaydedilir (sayfa biriminde); yakınlaştırma ölçekle çizer.
  ui.Picture get picture => _picture ??= () {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawPath(
      inkOutlinePath(points, brush, complete: true),
      inkPaintFor(brush),
    );
    return rec.endRecording();
  }();

  void dispose() {
    _picture?.dispose();
    _picture = null;
  }
}

/// Bir sayfanın çizgileri (bellekte önbellek). Çizim sırasında kayıttan yeniden
/// çözme yok: yalnızca açılışta ve geri al/yinele geri getirmesinde okunur.
class PagePen extends ChangeNotifier {
  PagePen(this.page);
  final int page;
  final List<PenStroke> _strokes = [];
  bool _disposed = false;

  List<PenStroke> get strokes => List.unmodifiable(_strokes);

  void _add(PenStroke s) {
    _strokes.add(s);
    _ping();
  }

  void _removeWhere(bool Function(PenStroke) test) {
    final gone = _strokes.where(test).toList();
    if (gone.isEmpty) return;
    _strokes.removeWhere(test);
    _ping();
    for (final s in gone) {
      s.dispose();
    }
  }

  /// Kayıttan gelenler + henüz kaydı bitmemiş (id'siz) bellek çizgileri.
  void _replaceLoaded(List<PenStroke> loaded) {
    final pending = _strokes.where((s) => s.id == null).toList();
    final old = _strokes.where((s) => s.id != null).toList();
    _strokes
      ..clear()
      ..addAll(loaded)
      ..addAll(pending);
    _ping();
    for (final s in old) {
      s.dispose();
    }
  }

  void _ping() {
    if (!_disposed) notifyListeners();
  }

  /// [canvas]'ı sayfa birimli çizer; [scaleX]/[scaleY] görünüm piksel / sayfa birimi.
  void paint(ui.Canvas canvas, double scaleX, double scaleY) {
    canvas.save();
    canvas.scale(scaleX, scaleY);
    for (final s in _strokes) {
      canvas.drawPicture(s.picture);
    }
    canvas.restore();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _strokes) {
      s.dispose();
    }
    _strokes.clear();
    super.dispose();
  }
}

/// Bir PDF belgesinin kalem oturumu: araç durumu, sayfa çizgileri, kayıt,
/// geri al / yinele. Okuyucu ekranının ve sayfa katmanlarının ortak durumu.
class PdfInkSession extends ChangeNotifier {
  PdfInkSession({
    required this.documentId,
    required this.repository,
    DateTime Function()? clock,
    this.attemptNo = 1,
    this.layer = 0,
  }) : _clock = clock ?? DateTime.now;

  final String documentId;
  final InkStrokeRepository repository;
  final DateTime Function() _clock;
  final int attemptNo;
  final int layer;

  final Map<int, PagePen> _pens = {};
  final InkHistory _history = InkHistory();
  final Set<int> _activePens = {};
  bool _disposed = false;

  /// Kayıt/geri al işleri sırayla çalışır (yarış yok).
  Future<void> _queue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final run = _queue.then((_) => job());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Tüm kayıt işlerinin bitmesini bekler (test ve kapanış için).
  Future<void> flush() => _queue;

  // --- araç durumu ---
  InkBrush _brush = const InkBrush();
  InkBrush get brush => _brush;
  void setBrush(InkBrush b) {
    _brush = b;
    notifyListeners();
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  // --- kalem teması: kalem çizerken ikinci temas görünümü oynatmaz ---
  bool get penActive => _activePens.isNotEmpty;
  void penDown(int pointer) => _activePens.add(pointer);
  void penUp(int pointer) => _activePens.remove(pointer);

  // --- sayfa katmanları (kalem olaylarını yönlendirmek için) ---
  final List<PdfPageInkLayerState> _layers = [];
  void registerLayer(PdfPageInkLayerState l) {
    if (!_layers.contains(l)) _layers.add(l);
  }

  void unregisterLayer(PdfPageInkLayerState l) => _layers.remove(l);

  /// [global] noktasındaki sayfa katmanı (yoksa null).
  PdfPageInkLayerState? layerAt(ui.Offset global) {
    for (final l in _layers.reversed) {
      if (l.containsGlobal(global)) return l;
    }
    return null;
  }

  // --- sayfalar ---
  PagePen penFor(int page) {
    final existing = _pens[page];
    if (existing != null) return existing;
    final pen = _pens[page] = PagePen(page);
    unawaited(_enqueue(() => _load(pen)));
    return pen;
  }

  PdfPageOwner _owner(int page) => PdfPageOwner(documentId, page);

  Future<void> _load(PagePen pen) async {
    if (_disposed) return;
    final rows = await repository.forPage(
      _owner(pen.page),
      attemptNo: attemptNo,
      layer: layer,
    );
    if (_disposed) return;
    pen._replaceLoaded([for (final r in rows) _fromRecord(r)]);
  }

  PenStroke _fromRecord(InkStroke r) => PenStroke(
    InkBrush(tool: _toolOf(r.tool), color: r.color, width: r.width),
    [
      for (final p in r.points)
        InkPoint(
          x: p.x,
          y: p.y,
          pressure: p.pressure,
          tilt: p.tilt,
          tMs: p.t.toDouble(),
        ),
    ],
    id: r.id,
  );

  static InkTool _toolOf(String name) => InkTool.values.firstWhere(
    (t) => t.name == name,
    orElse: () => InkTool.pen,
  );

  /// Biten çizgi: [viewPoints]/[viewBrush] görünüm pikselinde; sayfa birimine
  /// çevrilir, hemen ekranda görünür, kayıt arkada yapılır.
  void addStroke(
    int page,
    InkBrush viewBrush,
    List<InkPoint> viewPoints,
    PageCoords coords,
  ) {
    if (viewPoints.isEmpty || viewBrush.tool == InkTool.eraser) return;
    final t0 = viewPoints.first.tMs;
    final pts = <InkPoint>[
      for (final p in viewPoints)
        () {
          final o = coords.toPage(ui.Offset(p.x, p.y));
          return InkPoint(
            x: o.dx,
            y: o.dy,
            pressure: p.pressure,
            tilt: p.tilt,
            tMs: p.tMs - t0,
          );
        }(),
    ];
    final stroke = PenStroke(
      viewBrush.copyWith(width: viewBrush.width * coords.pageUnitsPerViewPx),
      pts,
    );
    penFor(page)._add(stroke);
    final startedAt = _clock().millisecondsSinceEpoch;
    unawaited(
      _enqueue(() async {
        final id = await repository.add(
          owner: _owner(page),
          points: [
            for (final p in pts)
              StrokePoint(
                p.x,
                p.y,
                pressure: p.pressure,
                tilt: p.tilt,
                t: math.max<int>(0, p.tMs.round()),
              ),
          ],
          startedAtMs: startedAt,
          layer: layer,
          attemptNo: attemptNo,
          tool: stroke.brush.tool.name,
          color: stroke.brush.color,
          width: stroke.brush.width,
        );
        stroke.id = id;
        _history.push(InkAction(InkActionKind.added, page, [id]));
        _ping();
      }),
    );
  }

  /// Silgi: sayfa noktasına (x, y) [radius] sayfa biriminde değen çizgileri
  /// ekrandan kaldırır ve kaldırılanları döner (kayıt [commitErase] ile).
  List<PenStroke> eraseAt(int page, double x, double y, double radius) {
    final pen = penFor(page);
    final hit = [
      for (final s in pen._strokes)
        if (strokeHitsPoint(
          s.points,
          x,
          y,
          radius,
          halfWidth: s.brush.width / 2,
        ))
          s,
    ];
    if (hit.isNotEmpty) pen._removeWhere(hit.contains);
    return hit;
  }

  /// Silgi hareketi bitti: kaldırılan çizgileri yumuşak siler (geri alınabilir).
  void commitErase(int page, List<PenStroke> removed) {
    if (removed.isEmpty) return;
    unawaited(
      _enqueue(() async {
        final ids = [
          for (final s in removed)
            if (s.id != null) s.id!,
        ];
        await repository.softDeleteMany(ids);
        _history.push(InkAction(InkActionKind.erased, page, ids));
        _ping();
      }),
    );
  }

  Future<void> undo() => _enqueue(() async {
    final a = _history.takeUndo();
    if (a == null) return;
    await _apply(a, forward: false);
    _history.commitUndo(a);
    _ping();
  });

  Future<void> redo() => _enqueue(() async {
    final a = _history.takeRedo();
    if (a == null) return;
    await _apply(a, forward: true);
    _history.commitRedo(a);
    _ping();
  });

  /// [forward]: eylemi (yeniden) uygula; değilse tersini.
  Future<void> _apply(InkAction a, {required bool forward}) async {
    final deleteThem = (a.kind == InkActionKind.added) != forward;
    final pen = _pens[a.page];
    if (deleteThem) {
      await repository.softDeleteMany(a.strokeIds);
      pen?._removeWhere((s) => s.id != null && a.strokeIds.contains(s.id));
    } else {
      for (final id in a.strokeIds) {
        await repository.restore(id);
      }
      if (pen != null) await _load(pen);
    }
  }

  void _ping() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final p in _pens.values) {
      p.dispose();
    }
    _pens.clear();
    super.dispose();
  }
}
