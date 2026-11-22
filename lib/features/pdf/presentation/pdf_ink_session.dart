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

  /// Kayıt başlangıcı (epoch ms); kayıt yeniden denenirken aynı kalır.
  int startedAtMs = 0;

  /// Kayıt tüm denemelere rağmen başarısız oldu (çizgi ekranda, sonra yeniden denenir).
  bool failed = false;

  /// Silgiyle ekrandan kaldırıldı; kaydı bitmemişse bitince hemen yumuşak silinir.
  bool erased = false;

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
  bool get isDisposed => _disposed;

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
    this.retryDelays = const [
      Duration(milliseconds: 300),
      Duration(seconds: 1),
      Duration(seconds: 3),
    ],
    this.hoverHold = const Duration(milliseconds: 800),
  }) : _clock = clock ?? DateTime.now;

  final String documentId;
  final InkStrokeRepository repository;
  final DateTime Function() _clock;
  final int attemptNo;
  final int layer;

  /// Kayıt hatasında bekleme süreleri (sınırlı yeniden deneme; sonra kullanıcıya ikaz).
  final List<Duration> retryDelays;

  /// Kalem havada yaklaştıktan sonra görünümün kilitli kaldığı süre.
  final Duration hoverHold;

  final Map<int, PagePen> _pens = {};
  final Set<String> _pendingErase = {};
  final List<PenStroke> _failed = [];
  final Map<PenStroke, int> _failedPage = {};
  final _errors = StreamController<String>.broadcast();
  bool _erasing = false;
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

  /// Kaydı bekleyen/başarısız çizgileri bir kez daha dener ve tüm kayıt
  /// işlerinin bitmesini bekler (kapanış, uygulama arka plana giderken, test).
  Future<void> flush() {
    // Başarısız çizgi yoksa yalnızca kuyruğu bekle; varsa kuyruğa yeniden deneme ekle.
    if (_failed.isEmpty) return _queue;
    return _enqueue(_retryFailed);
  }

  /// Kalıcı kayıt hatalarında kullanıcıya gösterilecek iletiler.
  Stream<String> get errors => _errors.stream;

  void _report(String msg) {
    if (!_errors.isClosed) _errors.add(msg);
  }

  /// [op]'u gecikmeli sınırlı yeniden deneme ile çalıştırır; başarı döner.
  /// Hata asla dışarı sızmaz (işlenmemiş zone hatası yok).
  Future<bool> _try(Future<void> Function() op) async {
    for (var i = 0; ; i++) {
      try {
        await op();
        return true;
      } catch (e) {
        debugPrint('PdfInkSession kayıt hatası (deneme ${i + 1}): $e');
        if (i >= retryDelays.length) return false;
        await Future<void>.delayed(retryDelays[i]);
      }
    }
  }

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
  void penDown(int pointer) {
    _activePens.add(pointer);
    _updateLock();
  }

  void penUp(int pointer) {
    _activePens.remove(pointer);
    _updateLock();
  }

  /// Görünümün kaydırma/yakınlaştırması kapalı mı: kalem çiziyor ya da bir
  /// sayfanın üstünde havada (avuç kalemden önce değse bile sayfa kaymaz).
  final ValueNotifier<bool> viewerLocked = ValueNotifier(false);
  bool _near = false;
  Timer? _nearTimer;

  void _updateLock() {
    if (_disposed) return;
    viewerLocked.value = penActive || _near;
  }

  /// Kalem havada: [overPage] sayfanın üstündeyse görünüm [hoverHold] boyunca
  /// kilitli kalır (olay geldikçe uzar). Sayfa dışında kilit açılır.
  void penHover({required bool overPage}) {
    _nearTimer?.cancel();
    _near = overPage;
    _updateLock();
    if (overPage) {
      _nearTimer = Timer(hoverHold, () {
        _near = false;
        _updateLock();
      });
    }
  }

  /// Silgi hareketi sürüyor: geri al / yinele kapalı (yarış olmasın).
  bool get erasing => _erasing;
  void setErasing(bool v) {
    if (_erasing == v) return;
    _erasing = v;
    _ping();
  }

  // --- "Soru seç" aracı: kalem çizmek yerine dikdörtgen sürüklenir ---
  bool _selecting = false;
  bool get selecting => _selecting;
  void setSelecting(bool v) {
    if (_selecting == v) return;
    _selecting = v;
    _ping();
  }

  /// Sürüklenen kutu bırakıldı: iki köşe SAYFA biriminde (ham; normalizasyon
  /// çağıranın işi), sayfa boyutu görünen (döndürülmüş) sayfanın boyutu.
  void Function(int page, double x1, double y1, double x2, double y2, double pageWidth, double pageHeight)?
      onSelectBox;

  // --- sayfa katmanları (kalem olaylarını yönlendirmek için) ---
  final List<PdfPageInkLayerState> _layers = [];
  void registerLayer(PdfPageInkLayerState l) {
    if (!_layers.contains(l)) _layers.add(l);
  }

  /// [page]: katmanın bıraktığı sayfa (katman sayfa değiştirirken eskisi).
  /// Sayfanın başka katmanı ve kaydı bitmemiş çizgisi yoksa bellekten atılır.
  void unregisterLayer(PdfPageInkLayerState l, {required int page}) {
    _layers.remove(l);
    final pen = _pens[page];
    if (pen == null || _layers.any((x) => x.page == page)) return;
    if (pen._strokes.any((s) => s.id == null)) return;
    _pens.remove(page);
    pen.dispose();
  }

  @visibleForTesting
  int get cachedPages => _pens.length;

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
    unawaited(
      _enqueue(() async {
        if (!await _try(() => _load(pen))) {
          _report('Çizgiler yüklenemedi. Sayfayı kapatıp yeniden aç.');
        }
      }),
    );
    return pen;
  }

  PdfPageOwner _owner(int page) => PdfPageOwner(documentId, page);

  Future<void> _load(PagePen pen) async {
    if (_disposed || pen._disposed) return;
    final rows = await repository.forPage(
      _owner(pen.page),
      attemptNo: attemptNo,
      layer: layer,
    );
    if (_disposed || pen._disposed) return;
    pen._replaceLoaded([
      for (final r in rows)
        // Silgiyle kaldırılıp kaydı bekleyen çizgi geri gelmesin.
        if (!_pendingErase.contains(r.id)) _fromRecord(r),
    ]);
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
    )..startedAtMs = _clock().millisecondsSinceEpoch;
    penFor(page)._add(stroke);
    unawaited(_enqueue(() => _save(page, stroke)));
  }

  /// Çizgiyi kaydeder (gecikmeli yeniden deneme). Başarısızsa çizgi ekranda
  /// kalır, [_failed]'e girer ve sonraki [flush]'ta yeniden denenir.
  Future<void> _save(int page, PenStroke stroke) async {
    if (stroke.erased) {
      _failed.remove(stroke);
      _failedPage.remove(stroke);
      return; // kaydedilmeden silindi: kayıt hiç oluşmasın
    }
    String? id;
    final ok = await _try(() async {
      id = await repository.add(
        owner: _owner(page),
        points: [
          for (final p in stroke.points)
            StrokePoint(
              p.x,
              p.y,
              pressure: p.pressure,
              tilt: p.tilt,
              t: math.max<int>(0, p.tMs.round()),
            ),
        ],
        startedAtMs: stroke.startedAtMs,
        layer: layer,
        attemptNo: attemptNo,
        tool: stroke.brush.tool.name,
        color: stroke.brush.color,
        width: stroke.brush.width,
      );
    });
    if (!ok) {
      final first = !stroke.failed;
      stroke.failed = true;
      if (!_failed.contains(stroke)) _failed.add(stroke);
      _failedPage[stroke] = page;
      if (first) {
        _report('Çizgi kaydedilemedi; ekranda duruyor, yeniden denenecek.');
      }
      return;
    }
    stroke.failed = false;
    _failed.remove(stroke);
    _failedPage.remove(stroke);
    stroke.id = id;
    if (stroke.erased) {
      // Kayıt sürerken silgiyle kaldırılmıştı: şimdi yumuşak sil.
      await _try(() => repository.softDeleteMany([id!]));
      return;
    }
    _history.push(InkAction(InkActionKind.added, page, [id!]));
    _ping();
  }

  Future<void> _retryFailed() async {
    for (final s in List.of(_failed)) {
      await _save(_failedPage[s] ?? 0, s);
    }
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
    if (hit.isNotEmpty) {
      for (final s in hit) {
        s.erased = true;
        if (s.id != null) _pendingErase.add(s.id!);
      }
      pen._removeWhere(hit.contains);
    }
    return hit;
  }

  /// Silgi hareketi bitti: kaldırılan çizgileri yumuşak siler (geri alınabilir).
  /// Kayıt başarısızsa çizgiler ekrana geri konur.
  void commitErase(int page, List<PenStroke> removed) {
    if (removed.isEmpty) return;
    unawaited(
      _enqueue(() async {
        final ids = [
          for (final s in removed)
            if (s.id != null) s.id!,
        ];
        final ok = ids.isEmpty || await _try(() async {
          await repository.softDeleteMany(ids);
        });
        _pendingErase.removeAll(ids);
        if (!ok) {
          final pen = _pens[page];
          for (final s in removed) {
            s.erased = false;
            if (pen != null && !pen._disposed) pen._add(s);
          }
          _report('Silme kaydedilemedi; çizgiler geri konuldu.');
          return;
        }
        _history.push(InkAction(InkActionKind.erased, page, ids));
        _ping();
      }),
    );
  }

  Future<void> undo() => _enqueue(() async {
    if (_erasing) return;
    final a = _history.takeUndo();
    if (a == null) return;
    if (!await _try(() => _apply(a, forward: false))) {
      _history.returnUndo(a);
      _report('Geri alınamadı.');
      _ping();
      return;
    }
    _history.commitUndo(a);
    _ping();
  });

  Future<void> redo() => _enqueue(() async {
    if (_erasing) return;
    final a = _history.takeRedo();
    if (a == null) return;
    if (!await _try(() => _apply(a, forward: true))) {
      _history.returnRedo(a);
      _report('Yinelenemedi.');
      _ping();
      return;
    }
    _history.commitRedo(a);
    _ping();
  });

  /// [forward]: eylemi (yeniden) uygula; değilse tersini. Tekrarlanabilir (idempotent).
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
    _nearTimer?.cancel();
    viewerLocked.dispose();
    _errors.close();
    for (final p in _pens.values) {
      p.dispose();
    }
    _pens.clear();
    super.dispose();
  }
}
