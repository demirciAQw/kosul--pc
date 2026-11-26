import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../ink/data/ink_outline.dart';
import '../../ink/data/ink_overlay_host.dart';
import '../../ink/data/ink_stroke_repository.dart';
import '../../ink/domain/eraser.dart';
import '../../ink/domain/ink_geometry.dart';
import '../../ink/domain/ink_models.dart';
import '../../ink/domain/ink_object.dart';
import '../../ink/domain/lasso.dart';
import '../../ink/domain/hold_detector.dart';
import '../../ink/domain/shape_recognizer.dart' show ShapeTool;
import '../../ink/domain/pen_profiles.dart';
import '../../ink/domain/ink_stroke_record.dart';
import '../../ink/domain/stroke_codec.dart';
import '../../ink/domain/stroke_lod.dart';
import '../../ink/presentation/zoom_interaction.dart';
import '../../../core/pen_diag.dart';
import '../domain/ink_history.dart';
import '../domain/palm_rejector.dart';
import '../domain/page_coords.dart';
import 'pdf_ink_overlay.dart';
import 'pdf_page_ink_layer.dart';

/// Sayfada duran bir çizgi. Noktalar ve kalınlık SAYFA biriminde; [id] kayıt
/// bitene kadar null (iyimser ekleme).
class PenStroke {
  PenStroke(this.brush, this.points, {this.id, this.layer = 0});
  String? id;

  /// Çizginin katman anahtarı (kalıcı, bkz. PdfPageLayer.key) (`ink_strokes.layer`); 0 = ana çizim.
  int layer;
  final InkBrush brush;
  List<InkPoint> points;
  ui.Picture? _picture;
  List<InkPoint>? _boundsOf;
  ui.Rect? _bounds;
  ui.Picture? _light;

  /// Noktaların kaba sınır kutusu (kalınlık hariç); alan silgisi ön elemesi için önbellekli.
  ui.Rect get bounds {
    if (_bounds != null && identical(_boundsOf, points)) return _bounds!;
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (final p in points) {
      if (p.x < l) l = p.x;
      if (p.x > r) r = p.x;
      if (p.y < t) t = p.y;
      if (p.y > b) b = p.y;
    }
    _boundsOf = points;
    return _bounds = points.isEmpty ? ui.Rect.zero : ui.Rect.fromLTRB(l, t, r, b);
  }

  /// Kement taşıma/boyutlandırma önizlemesi: noktaları değiştirir, resim yeniden çizilir.
  void setPoints(List<InkPoint> p) {
    points = p;
    _picture?.dispose();
    _picture = null;
    _light?.dispose();
    _light = null;
  }

  /// Kayıt başlangıcı (epoch ms); kayıt yeniden denenirken aynı kalır.
  int startedAtMs = 0;

  /// Kayıt tüm denemelere rağmen başarısız oldu (çizgi ekranda, sonra yeniden denenir).
  bool failed = false;

  /// Silgiyle ekrandan kaldırıldı; kaydı bitmemişse bitince hemen yumuşak silinir.
  bool erased = false;

  /// Çizgi resmi bir kez kaydedilir (sayfa biriminde); yakınlaştırma ölçekle çizer.
  ui.Picture get picture => _picture ??= () {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawPath(inkOutlinePath(points, brush, complete: true), inkPaintFor(brush));
    return rec.endRecording();
  }();

  /// Hafif çizim (zum/kaydırma sırasında): seyreltilmiş noktalardan ince çoklu çizgi,
  /// düz alfa (multiply/saveLayer yok). Çizgi başına bir kez kaydedilir, zumdan bağımsız.
  ui.Picture get lightPicture => _light ??= () {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    final paint = inkPaintFor(brush)
      ..blendMode = ui.BlendMode.srcOver
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = brush.width
      ..strokeCap = ui.StrokeCap.round
      ..strokeJoin = ui.StrokeJoin.round;
    final pts = simplifyPoints<InkPoint>(points, math.max(0.25, brush.width * 0.1), (p) => p.x, (p) => p.y);
    if (pts.length == 1) {
      c.drawPoints(ui.PointMode.points, [ui.Offset(pts.first.x, pts.first.y)], paint);
    } else if (pts.length > 1) {
      final path = ui.Path()..moveTo(pts.first.x, pts.first.y);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].x, pts[i].y);
      }
      c.drawPath(path, paint);
    }
    return rec.endRecording();
  }();

  void dispose() {
    _picture?.dispose();
    _picture = null;
    _light?.dispose();
    _light = null;
  }
}

/// Etkileşim sırasında kare başına en çok bu kadar nokta çizilir (aşılırsa en eski çizgiler atlanır).
const lightPointBudget = 20000;

/// Bir sayfanın çizgileri (bellekte önbellek). Çizim sırasında kayıttan yeniden
/// çözme yok: yalnızca açılışta ve geri al/yinele geri getirmesinde okunur.
class PagePen extends ChangeNotifier {
  PagePen(this.page);
  final int page;
  final List<PenStroke> _strokes = [];
  bool _disposed = false;

  /// null: hepsi görünür; verilirse YALNIZ bu katmanın çizgileri çizilir/silinir/seçilir
  /// (önbellekten süzülür, yeniden yükleme yok).
  int? _onlyLayer;

  Iterable<PenStroke> get _shown => _onlyLayer == null ? _strokes : _strokes.where((s) => s.layer == _onlyLayer);

  void _setOnlyLayer(int? v) {
    if (_onlyLayer == v) return;
    _onlyLayer = v;
    _ping();
  }

  List<PenStroke> get strokes => List.unmodifiable(_strokes);

  void _add(PenStroke s) {
    _strokes.add(s);
    _ping();
  }

  /// [old]'u aynı z-sırasında [news] ile değiştirir (alan silgisi).
  void _replaceOne(PenStroke old, List<PenStroke> news) {
    final i = _strokes.indexOf(old);
    if (i < 0) return;
    _strokes.replaceRange(i, i + 1, news);
    _ping();
    old.dispose();
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
  /// [light]: zum/kaydırma sürüyor: yalnız [viewport] (katman yerel pikseli) içindeki,
  /// ekranda ~0.5 px'ten büyük çizgiler, [lightPointBudget] içinde, hafif çizimle çizilir.
  /// [zoom]: yerel piksel -> ekran pikseli.
  void paint(
    ui.Canvas canvas,
    double scaleX,
    double scaleY, {
    double originX = 0,
    double originY = 0,
    bool light = false,
    ui.Rect? viewport,
    double zoom = 1,
  }) {
    canvas.save();
    canvas.scale(scaleX, scaleY);
    canvas.translate(-originX, -originY);
    if (!light) {
      for (final s in _shown) {
        canvas.drawPicture(s.picture);
      }
    } else {
      final vis = viewport == null
          ? null
          : LodRect(
              viewport.left / scaleX + originX,
              viewport.top / scaleY + originY,
              viewport.right / scaleX + originX,
              viewport.bottom / scaleY + originY,
            );
      final margin = vis == null ? 0.0 : math.max(vis.width, vis.height) * 0.1;
      final screen = math.max(scaleX, scaleY) * zoom;
      final cand = <PenStroke>[];
      for (final s in _shown) {
        if (s.points.isEmpty) continue;
        final b = s.bounds, w = s.brush.width;
        if (vis != null && !LodRect(b.left - w, b.top - w, b.right + w, b.bottom + w).overlaps(vis.inflate(margin))) {
          continue;
        }
        // Ekranda 0.5 px'ten küçük ayrıntı (kalınlık dahil) atlanır.
        if (math.max(b.width, b.height) * screen < 0.5 && w * screen < 0.5) continue;
        cand.add(s);
      }
      final keep = pointBudget([for (final s in cand) s.points.length], lightPointBudget);
      for (var i = 0; i < cand.length; i++) {
        if (keep[i]) canvas.drawPicture(cand[i].lightPicture);
      }
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

/// Kement seçimi: sayfa ve seçilen çizgilerin KAYITLI noktaları (kimlikle).
class _Selection {
  _Selection(this.page, this.baseline);
  final int page;
  final Map<String, List<InkPoint>> baseline;
}

/// Silgi türü: çizgiyi bütün siler ya da yalnız değdiği yeri keser.
enum EraseMode { stroke, area }

/// Alan silgisi: sürüklenen bir hareketin geçici durumu (hareket sonunda tek kayıt).
class _AreaMove {
  _AreaMove(this.page);
  final int page;

  /// Hareket başında sayfada duran (kayıtlı ya da kaydı süren) özgün çizgiler.
  final List<PenStroke> originals = [];

  /// Şu an ekranda duran, henüz kaydedilmemiş parçalar.
  final List<PenStroke> pieces = [];
}

/// Bir PDF belgesinin (ya da defter sayfasının) kalem oturumu: araç durumu, sayfa çizgileri, kayıt,
/// geri al / yinele. Okuyucu ekranının ve sayfa katmanlarının ortak durumu.
class PdfInkSession extends ChangeNotifier {
  PdfInkSession({
    required this.documentId,
    required this.repository,
    DateTime Function()? clock,
    this.attemptNo = 1,
    this.questionId,
    int layer = 0,
    this.allLayers = false,
    this.strokeTag,
    this.strokeFilter,
    this.retryDelays = const [Duration(milliseconds: 300), Duration(seconds: 1), Duration(seconds: 3)],
    this.hoverHold = const Duration(milliseconds: 500),
    this.ownerOf,
    this.penKinds = false,
    this.holdMs = shapeHoldMs,
    this.holdTolerancePx = shapeHoldTolerancePx,
  }) : _clock = clock ?? DateTime.now,
       _layer = layer;

  final String documentId;

  /// Verilirse çizgi sahibi sayfa numarasından bu işlevle bulunur (defter sayfası:
  /// `NotePageOwner(sayfaId, pageNo)`); null ise PDF sayfası.
  final StrokeOwner Function(int page)? ownerOf;

  /// Kalem türü (tükenmez/dolma/kurşun/fosforlu) `tool` sütununa yazılır ve geri okunur.
  final bool penKinds;
  final InkStrokeRepository repository;
  final DateTime Function() _clock;
  final int attemptNo;

  /// Verilirse oturum yalnızca o sorunun çözüm çizgilerini okur/yazar (çözüm
  /// ekranı); null ise yalnızca soruya bağlı OLMAYAN çizgileri (okuyucu).
  final String? questionId;

  /// Yeni çizgilerin katman anahtarı (AKTİF katman, `ink_strokes.layer`); okuyucuda değişir.
  int _layer;
  int get layer => _layer;

  /// [allLayers] iken yalnız bu katmanın çizgileri görünür: değişince sayfalar önbellekten süzülür.
  set layer(int v) {
    if (_layer == v) return;
    _layer = v;
    if (!allLayers) return;
    for (final pen in _pens.values) {
      pen._setOnlyLayer(v);
    }
  }

  /// true: sayfadaki TÜM katmanların çizgileri belleğe okunur (okuyucu); YALNIZ [layer] görünür/silinir/seçilir, yazma da ona.
  final bool allLayers;

  /// `noteId` sütunundaki ayırt edici: katman penceresi 'katman-pencere:<id>' yazar/okur;
  /// null ise yalnız ayırıcısız çizgiler (ana okuyucu).
  final String? strokeTag;

  /// Çizgi kabul süzgeci: (sayfa, katman, sayfa-birimi ilk nokta) -> kabul. Soru katmanı bölge dışını reddeder.
  final bool Function(int page, int layer, ui.Offset pagePoint)? strokeFilter;

  /// Kayıt hatasında bekleme süreleri (sınırlı yeniden deneme; sonra kullanıcıya ikaz).
  final List<Duration> retryDelays;

  /// Kalem havada yaklaştıktan sonra görünümün kilitli kaldığı süre.
  final Duration hoverHold;

  /// Şekil düzeltme: kalem bu kadar ms hareketsiz basılı kalırsa ([holdTolerancePx]
  /// görünüm pikseli içinde) çizgi tanınan şekle dönüşür. Ayarlanabilir; testte kısaltılır.
  final int holdMs;
  final double holdTolerancePx;

  /// Zum/kaydırma sırasında hafif çizim bayrağı (boyayıcılar dinler).
  final zoomInteraction = ZoomInteraction();

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

  EraseMode _eraseMode = EraseMode.stroke;
  EraseMode get eraseMode => _eraseMode;
  void setEraseMode(EraseMode m) {
    if (_eraseMode == m) return;
    _eraseMode = m;
    notifyListeners();
  }

  double _hardness = 0.5;

  /// Baskı eğrisi sertliği (0..1; bkz. `pressureFactor`).
  double get hardness => _hardness;
  void setHardness(double v) {
    _hardness = v.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// Ham baskıyı (0..1) seçili sertlikle biçimlendirir; kalem türü yoksa aynen döner.
  /// Çizgi hem canlı çizilirken hem kaydedilirken AYNI biçimlenmiş baskıyı taşır.
  double shapePressure(double raw) => _brush.kind == null || !(penProfiles[_brush.kind]?.pressureSensitive ?? false)
      ? raw
      : pressureFactor(raw, _hardness);

  /// Şekil düzeltme açık mı (basılı tutunca düz çizgi/daire/dörtgen...). PDF okuyucuda varsayılan kapalı.
  bool _shapeSnap = false;
  bool get shapeSnap => _shapeSnap;
  void setShapeSnap(bool v) {
    if (_shapeSnap == v) return;
    _shapeSnap = v;
    notifyListeners();
  }

  /// Doğrudan şekil aracı (sürükle, bırakınca mükemmel şekil); null ise kapalı.
  /// Silgi/kement açıkken yok sayılır.
  ShapeTool? _shapeTool;
  ShapeTool? get shapeTool => _shapeTool;
  void setShapeTool(ShapeTool? v) {
    if (_shapeTool == v) return;
    _shapeTool = v;
    notifyListeners();
  }

  // --- kement aracı ---
  bool _lassoMode = false;

  /// Kement açıkken kalem çizmez; kapalı yol çizip çizgileri seçer.
  bool get lassoMode => _lassoMode;
  void setLassoMode(bool v) {
    if (_lassoMode == v) return;
    _lassoMode = v;
    if (!v) clearSelection();
    notifyListeners();
  }

  _Selection? _sel;
  int _busy = 0;

  /// Seçim değişince (önizleme dahil) çerçeveyi yeniden çizdirir.
  final ValueNotifier<int> selectionTick = ValueNotifier(0);

  bool get hasSelection => _sel != null && _selStrokes().isNotEmpty;
  int get selectionPage => _sel?.page ?? -1;

  /// Seçilen çizgiler yazılırken (kısa) yeni sürükleme başlamaz.
  bool get selectionBusy => _busy > 0;

  List<PenStroke> _selStrokes() {
    final sel = _sel;
    if (sel == null) return const [];
    final pen = _pens[sel.page];
    if (pen == null) return const [];
    return [
      for (final s in pen._shown)
        if (s.id != null && sel.baseline.containsKey(s.id)) s,
    ];
  }

  /// Seçimin KAYITLI haldeki (sürükleme başı) çizgileri.
  List<InkObject> get selectionOriginals {
    final sel = _sel;
    if (sel == null) return const [];
    return [for (final s in _selStrokes()) InkObject(id: s.id!, points: sel.baseline[s.id]!, brush: s.brush)];
  }

  /// Seçimin şu anki (önizleme dahil) sınır kutusu; seçim yoksa null.
  InkRect? get selectionBoundsNow =>
      selectionBounds([for (final s in _selStrokes()) InkObject(id: s.id!, points: s.points, brush: s.brush)]);

  /// Seçimin kayıtlı sınır kutusu (sürükleme tutamakları buna göre).
  InkRect? get selectionBoundsSaved => selectionBounds(selectionOriginals);

  void _selChanged() {
    selectionTick.value++;
    _ping();
  }

  void clearSelection() {
    if (_sel == null) return;
    // Yarım kalmış önizleme varsa kayıtlı hale döndür.
    _restoreBaseline();
    _sel = null;
    _selChanged();
  }

  void _restoreBaseline() {
    final sel = _sel;
    if (sel == null) return;
    for (final s in _selStrokes()) {
      s.setPoints(sel.baseline[s.id]!);
    }
    _pens[sel.page]?._ping();
  }

  /// Kement yolu (SAYFA birimi) ile sayfadaki kayıtlı çizgileri seçer; kaç çizgi seçildi döner.
  /// Kaydı henüz bitmemiş (kimliksiz) çizgiler seçilmez.
  int selectLasso(int page, List<InkPoint> lasso) {
    _sel = null;
    final pen = _pens[page];
    if (pen == null || lasso.length < 3) {
      _selChanged();
      return 0;
    }
    final objs = [
      for (final s in pen._shown)
        if (s.id != null && !s.erased) InkObject(id: s.id!, points: s.points, brush: s.brush),
    ];
    final hit = selectByLasso(objs, lasso);
    if (hit.isNotEmpty) {
      _sel = _Selection(page, {for (final o in hit) o.id: List<InkPoint>.of(o.points)});
    }
    _selChanged();
    return hit.length;
  }

  /// Sürükleme önizlemesi: [transformed] kimlikle eşleşen çizgilerin noktalarını değiştirir.
  /// Veritabanına yazılmaz; [commitSelectionTransform] yazar, [cancelSelectionTransform] geri alır.
  void previewSelection(List<InkObject> transformed) {
    final sel = _sel;
    if (sel == null) return;
    final byId = {for (final o in transformed) o.id: o};
    for (final s in _selStrokes()) {
      final o = byId[s.id];
      if (o != null) s.setPoints(o.points);
    }
    _pens[sel.page]?._ping();
    _selChanged();
  }

  void cancelSelectionTransform() {
    _restoreBaseline();
    _selChanged();
  }

  /// Önizlemeyi TEK kalıcı işlemle yazar (çizgiler yerinde güncellenir), tek geri al kaydı.
  /// Hatada (yeniden denemeden sonra) çizgiler kayıtlı konuma döner ve kullanıcıya bildirilir.
  Future<void> commitSelectionTransform() {
    final sel = _sel;
    if (sel == null) return Future.value();
    final strokes = _selStrokes();
    final before = <String, List<InkPoint>>{};
    final after = <String, List<InkPoint>>{};
    for (final s in strokes) {
      final b = sel.baseline[s.id]!;
      if (_samePoints(b, s.points)) continue;
      before[s.id!] = b;
      after[s.id!] = List<InkPoint>.of(s.points);
    }
    if (after.isEmpty) {
      _selChanged();
      return Future.value();
    }
    _busy++;
    final page = sel.page;
    return _enqueue(() async {
      try {
        final ok = await _try(
          () => repository.updatePoints({for (final e in after.entries) e.key: _toRecord(e.value)}),
        );
        if (!ok) {
          // Hiçbir şey yazılmadı (işlem geri sarıldı): ekranı kayıtlı konuma döndür. Seçim bu arada
          // kalkmış olabilir; bu yüzden yakalanan [before] kimlikle doğrudan sayfaya uygulanır.
          _applyPoints(page, before);
          _report('Taşıma kaydedilemedi; çizgiler eski yerine döndü.');
          return;
        }
        // Başarı: ekran, seçim bu arada temizlenip eski tabana döndürülmüş olsa bile, DB ile aynı olsun.
        _applyPoints(page, after);
        for (final e in after.entries) {
          sel.baseline[e.key] = e.value;
        }
        _history.push(InkAction(InkActionKind.updated, page, after.keys.toList(), before: before, after: after));
      } finally {
        _busy--;
        _selChanged();
      }
    });
  }

  /// Sayfadaki çizgilerin noktalarını kimlikle verilen noktalara ayarlar (ekranı günceller).
  void _applyPoints(int page, Map<String, List<InkPoint>> byId) {
    final pen = _pens[page];
    if (pen == null || pen._disposed) return;
    for (final s in pen._strokes) {
      final p = byId[s.id];
      if (p != null) s.setPoints(p);
    }
    pen._ping();
  }

  static bool _samePoints(List<InkPoint> a, List<InkPoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
    }
    return true;
  }

  static List<StrokePoint> _toRecord(List<InkPoint> pts) => [
    for (final p in pts) StrokePoint(p.x, p.y, pressure: p.pressure, tilt: p.tilt, t: math.max<int>(0, p.tMs.round())),
  ];

  /// Seçilen çizgileri siler (yumuşak silme, geri alınabilir; hatada ekrana geri konur).
  void deleteSelection() {
    final sel = _sel;
    if (sel == null) return;
    final strokes = _selStrokes();
    _restoreBaseline();
    _sel = null;
    _selChanged();
    if (strokes.isEmpty) return;
    for (final s in strokes) {
      s.erased = true;
      _pendingErase.add(s.id!);
    }
    _pens[sel.page]?._removeWhere(strokes.contains);
    commitErase(sel.page, strokes);
  }

  /// Seçimin kopyası (kayıtlı konumda; kimlikler yapıştırırken yenilenir).
  /// Taşıma kaydı sürerken (busy) kayıtlı taban henüz eski konumdadır: yanlış konumu
  /// kopyalamamak için boş döner (çağıran önceki panoyu korur).
  List<InkObject> copySelection() => selectionBusy ? const [] : selectionOriginals;

  /// [objects]'i [dx],[dy] (sayfa birimi) kaydırarak yeni çizgi olarak ekler ve seçer.
  /// Tek işlem, tek geri al kaydı; hatada eklenenler kalkar.
  Future<void> pasteObjects(int page, List<InkObject> objects, {double dx = 24, double dy = 24}) {
    if (objects.isEmpty) return Future.value();
    final pen = penFor(page);
    final now = _clock().millisecondsSinceEpoch;
    final news = [
      for (final o in objects)
        PenStroke(o.brush, [
          for (final p in o.points) InkPoint(x: p.x + dx, y: p.y + dy, pressure: p.pressure, tilt: p.tilt, tMs: p.tMs),
        ], layer: layer)..startedAtMs = now,
    ];
    clearSelection();
    for (final n in news) {
      pen._add(n);
    }
    return _enqueue(() async {
      List<String> ids = const [];
      final ok = await _try(() async {
        ids = await repository.replace(deleteIds: const [], adds: [for (final n in news) _newStroke(page, n)]);
      });
      if (!ok) {
        final p = _pens[page];
        if (p != null && !p._disposed) p._removeWhere(news.contains);
        _report('Yapıştırma kaydedilemedi.');
        return;
      }
      for (var i = 0; i < news.length; i++) {
        news[i].id = ids[i];
      }
      _history.push(InkAction(InkActionKind.added, page, ids));
      _sel = _Selection(page, {for (final n in news) n.id!: List<InkPoint>.of(n.points)});
      _selChanged();
    });
  }

  bool get canUndo => _history.canUndo;
  bool get canRedo => _history.canRedo;

  // --- kalem teması: kalem çizerken ikinci temas görünümü oynatmaz ---
  bool get penActive => _activePens.isNotEmpty;

  /// Kalem bir sayfanın üstünde havada (hover zaman aşımına kadar).
  bool get penNear => _near;
  void penDown(int pointer, [ui.Offset? position, double? tMs]) {
    if (position != null) penPosition = position;
    _activePens.add(pointer);
    if (position != null && tMs != null) _palmPenEntered(tMs, position);
    _updateLock();
  }

  // --- geriye dönük avuç reddi (`palm_rejector.dart`): avuç kalemden ÖNCE değdiyse ---

  /// Görünüm dönüşümünü okuyan/yazan kancalar (sayfa kurar: `TransformationController`
  /// ya da `PdfViewerController`; anlık görüntü `Matrix4`). Verilmezse geri alma
  /// yapılmaz, yalnız avuç yutulur ve görünüm kilitlenir.
  Object? Function()? readViewMatrix;
  void Function(Object snapshot)? writeViewMatrix;

  /// Avuç izleyici (anlık görüntü türü: sayfanın verdiği dönüşüm).
  final PalmRejector<Object> palm = PalmRejector<Object>();

  /// Kalem girdi (hover başı ya da DOWN): yakın geçmişteki yakın temaslar avuç
  /// sayılır ve görünüm o temasların başladığı dönüşüme geri alınır.
  void _palmPenEntered(double tMs, ui.Offset pos) {
    final flagged = palm.penEntered(tMs: tMs, x: pos.dx, y: pos.dy);
    _restoreFor(flagged, tMs);
  }

  void _restoreFor(List<PalmTouch<Object>> flagged, double tMs) {
    if (flagged.isEmpty) return;
    final target = PalmRejector.restoreTarget<Object>(flagged);
    final write = writeViewMatrix;
    if (target != null && write != null) write(target);
    PenDiag.note(
      'karar=${PenDecision.palmRetro},${target != null && write != null ? PenDecision.viewRestored : 'geri-alma-yok'} '
      'ptr=${flagged.map((t) => t.pointer).join(',')}',
      tMs: tMs.round(),
    );
    _updateLock();
  }

  /// Yeni parmak teması kaydı (`InkPointerClaim`). [swallowed]: zaten yutulacak.
  /// Dönen: hemen avuç (yutulmalı).
  bool palmTouchDown({
    required int pointer,
    required double tMs,
    required ui.Offset position,
    required double radius,
    required bool swallowed,
  }) {
    final r = palm.touchDown(
      pointer: pointer,
      tMs: tMs,
      x: position.dx,
      y: position.dy,
      radius: radius,
      snapshot: swallowed ? null : readViewMatrix?.call(),
      passed: !swallowed,
    );
    if (r.flagged.isNotEmpty) _restoreFor(r.flagged, tMs);
    _updateLock();
    return r.selfPalm;
  }

  void palmTouchUp(int pointer) {
    palm.touchUp(pointer);
    _updateLock();
  }

  void penUp(int pointer) {
    _activePens.remove(pointer);
    _updateLock();
  }

  /// Görünümün kaydırma/yakınlaştırması kapalı mı: YALNIZ kalem aşağıdayken
  /// (çizerken). Kalem havadayken kilit AÇIK: diğer elle zum/kaydırma çalışır;
  /// yazan elin avucu temas bazında yutulur ([isPalmNearPen], `InkPointerClaim`).
  final ValueNotifier<bool> viewerLocked = ValueNotifier(false);

  /// Kalemin son bilinen ekran konumu (hover ya da aşağı); avuç mesafesi için.
  ui.Offset? penPosition;

  /// Kalem konumuna bu uzaklıktan (mantıksal px) yakın parmak teması, kalem
  /// havadayken yazan elin avucu sayılır ve yutulur. Tek sabit; uzaktaki
  /// (öbür el) temaslar görünüme geçer.
  static const double palmNearDistance = 350;

  /// Görünüme geçirilen (yutulmayan) aktif dokunmalar: biri görünümde sürerken
  /// gelen ikinci temas (iki parmak zum) yutulmaz.
  final Set<int> passedTouches = {};

  /// Kalem havada ve [p] kalem konumuna yakın mı (avuç adayı).
  bool isPalmNearPen(ui.Offset p) {
    final pos = penPosition;
    return _near && pos != null && (p - pos).distance <= palmNearDistance;
  }
  bool _near = false;
  Timer? _nearTimer;

  void _updateLock() {
    if (_disposed) return;
    // Kalem aşağıdayken ya da görünüme geçmiş bir AVUÇ basılıyken kilitli.
    viewerLocked.value = penActive || palm.anyPassedPalmDown;
  }

  /// Kalem havada: [overPage] sayfanın üstündeyse görünüm [hoverHold] boyunca
  /// kilitli kalır (olay geldikçe uzar). Sayfa dışında kilit açılır.
  void penHover({required bool overPage, ui.Offset? position, double? tMs}) {
    if (position != null) penPosition = position;
    // Hover BAŞLIYOR (yeni giriş): önceden değen yakın temaslar avuçtur.
    if (!_near && overPage && position != null && tMs != null) _palmPenEntered(tMs, position);
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
    if (v) {
      final m = _areaMove;
      if (m != null && m.originals.isEmpty && m.pieces.isEmpty) _areaMove = null; // değmeyen eski hareket
    }
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
  void Function(int page, double x1, double y1, double x2, double y2, double pageWidth, double pageHeight)? onSelectBox;

  // --- sayfa katmanları (kalem olaylarını yönlendirmek için) ---
  final List<PdfPageInkLayerState> _layers = [];

  /// Kayıtlı sayfa katmanları (Ink katmanı bölgeleri için; salt okunur görünüm).
  List<PdfPageInkLayerState> get layerStates => List.unmodifiable(_layers);

  /// Yerel Ink katmanı köprüsü (yalnız Android'de; masaüstü/testte null).
  PdfInkOverlay? _overlay;
  bool _overlayTried = false;
  PdfInkOverlay? _makeOverlay() {
    _overlayTried = true;
    return InkOverlayHost.instance.supported ? PdfInkOverlay(this) : null;
  }
  void registerLayer(PdfPageInkLayerState l) {
    if (!_layers.contains(l)) _layers.add(l);
    _overlay ??= _overlayTried ? null : _makeOverlay();
    _overlay?.layersChanged();
  }

  /// [page]: katmanın bıraktığı sayfa (katman sayfa değiştirirken eskisi).
  /// Sayfanın başka katmanı ve kaydı bitmemiş çizgisi yoksa bellekten atılır.
  void unregisterLayer(PdfPageInkLayerState l, {required int page}) {
    _layers.remove(l);
    _overlay?.layersChanged();
    final pen = _pens[page];
    if (pen == null || _layers.any((x) => x.page == page)) return;
    if (pen._strokes.any((s) => s.id == null)) return;
    _pens.remove(page);
    pen.dispose();
  }

  /// Bellekteki sayfalarda (kaydı bitmemiş olanlar dahil) çizgi var mı.
  bool get hasStrokes => _pens.values.any((p) => p._strokes.isNotEmpty);

  @visibleForTesting
  int get cachedPages => _pens.length;

  /// Kalem girişi kapalı (defterde Metin/Alt sayfa araçları): hiçbir katman kalem
  /// olayı almaz; kalem de parmak gibi görünümü kaydırır. Çizgiler olduğu gibi durur.
  bool _inkInputOff = false;
  bool get inkInputOff => _inkInputOff || _inkHidden;

  /// Çizimler gizli (göz düğmesi): çizgiler boyanmaz ve kalem yazmaz; veri olduğu gibi durur.
  bool _inkHidden = false;
  bool get inkHidden => _inkHidden;
  void setInkHidden(bool v) {
    if (_inkHidden == v) return;
    _inkHidden = v;
    _ping();
  }
  void setInkInputOff(bool v) {
    if (_inkInputOff == v) return;
    _inkInputOff = v;
    _ping();
  }

  /// [global] noktasındaki sayfa katmanı (yoksa null; giriş kapalıysa hep null).
  PdfPageInkLayerState? layerAt(ui.Offset global) {
    if (inkInputOff) return null;
    for (final l in _layers.reversed) {
      if (l.containsGlobal(global)) return l;
    }
    return null;
  }

  // --- sayfalar ---
  PagePen penFor(int page) {
    final existing = _pens[page];
    if (existing != null) return existing;
    final pen = _pens[page] = PagePen(page).._onlyLayer = allLayers ? _layer : null;
    unawaited(
      _enqueue(() async {
        if (!await _try(() => _load(pen))) {
          _report('Çizgiler yüklenemedi. Sayfayı kapatıp yeniden aç.');
        }
      }),
    );
    return pen;
  }

  StrokeOwner _owner(int page) => ownerOf?.call(page) ?? PdfPageOwner(documentId, page);

  Future<void> _load(PagePen pen) async {
    if (_disposed || pen._disposed) return;
    final rows = await repository.forPage(
      _owner(pen.page),
      attemptNo: attemptNo,
      layer: allLayers ? null : layer,
      questionId: questionId,
      noQuestion: questionId == null,
      tag: strokeTag,
    );
    if (_disposed || pen._disposed) return;
    pen._replaceLoaded([
      for (final r in rows)
        // Silgiyle kaldırılıp kaydı bekleyen çizgi geri gelmesin.
        if (!_pendingErase.contains(r.id)) _fromRecord(r),
    ]);
  }

  PenStroke _fromRecord(InkStroke r) => PenStroke(_brushOf(r), [
    for (final p in r.points) InkPoint(x: p.x, y: p.y, pressure: p.pressure, tilt: p.tilt, tMs: p.t.toDouble()),
  ], id: r.id, layer: r.layer);

  InkBrush _brushOf(InkStroke r) {
    final t = parseToolColumn(r.tool);
    final kind = penKinds ? PenKind.values.where((k) => k.name == t.name).firstOrNull : null;
    if (kind != null) {
      return InkBrush(
        tool: kind == PenKind.highlighter ? InkTool.highlighter : InkTool.pen,
        color: r.color,
        width: r.width,
        kind: kind,
        hardness: t.hardness,
      );
    }
    return InkBrush(tool: _toolOf(t.name), color: r.color, width: r.width);
  }

  static InkTool _toolOf(String name) => InkTool.values.firstWhere((t) => t.name == name, orElse: () => InkTool.pen);

  /// Biten çizgi: [viewPoints]/[viewBrush] görünüm pikselinde; sayfa birimine
  /// çevrilir, hemen ekranda görünür, kayıt arkada yapılır.
  void addStroke(int page, InkBrush viewBrush, List<InkPoint> viewPoints, PageCoords coords) {
    if (viewPoints.isEmpty || viewBrush.tool == InkTool.eraser) return;
    final t0 = viewPoints.first.tMs;
    // Canlı çizim biçimlenmiş baskı taşır ([shapePressure]); kayda HAM baskı + sertlik gider,
    // eğri çizimde uygulanır. Sabit baskılı çizgi (fare/parmak) olduğu gibi kalır.
    final profile = viewBrush.kind == null ? null : penProfiles[viewBrush.kind];
    final firstP = viewPoints.first.pressure;
    final varies = viewPoints.any((p) => p.pressure != firstP);
    final h = (profile?.pressureSensitive ?? false) && varies ? double.parse(_hardness.toStringAsFixed(2)) : null;
    final filter = strokeFilter;
    final pts = <InkPoint>[
      for (final p in viewPoints)
        () {
          final o = coords.toPage(ui.Offset(p.x, p.y));
          return InkPoint(
            x: o.dx,
            y: o.dy,
            pressure: h == null ? p.pressure : pressureUnfactor(p.pressure, _hardness),
            tilt: p.tilt,
            tMs: p.tMs - t0,
          );
        }(),
    ];
    if (filter != null && !filter(page, layer, ui.Offset(pts.first.x, pts.first.y))) return;
    final stroke = PenStroke(viewBrush.copyWith(width: viewBrush.width * coords.pageUnitsPerViewPx, hardness: h), pts, layer: layer)
      ..startedAtMs = _clock().millisecondsSinceEpoch - pts.last.tMs.round(); // saat çizgi SONUNDA okunur
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
            StrokePoint(p.x, p.y, pressure: p.pressure, tilt: p.tilt, t: math.max<int>(0, p.tMs.round())),
        ],
        startedAtMs: stroke.startedAtMs,
        layer: stroke.layer,
        tag: strokeTag,
        attemptNo: attemptNo,
        questionId: questionId,
        tool: toolColumnOf(stroke.brush),
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
  ///
  /// [EraseMode.area]: çizgi bütün kalkmaz, silgi yolu ([prevX]/[prevY]'den (x, y)'ye
  /// doğru parçası) üstündeki kısım kesilir; dönen liste bu çağrıda değişen çizgilerdir
  /// (kayıt yine [commitErase] ile, hareket başına tek kayıt).
  List<PenStroke> eraseAt(int page, double x, double y, double radius, {double? prevX, double? prevY}) {
    if (!x.isFinite || !y.isFinite || !radius.isFinite || radius < 0) return const [];
    if (_eraseMode == EraseMode.area) return _eraseArea(page, x, y, radius, prevX, prevY);
    final pen = penFor(page);
    final hit = [
      for (final s in pen._shown)
        if (strokeHitsPoint(s.points, x, y, radius, halfWidth: brushHalfWidth(s.brush))) s,
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

  _AreaMove? _areaMove;

  static bool _boxesTouch(ui.Rect a, ui.Rect b, double margin) =>
      a.left <= b.right + margin &&
      a.right >= b.left - margin &&
      a.top <= b.bottom + margin &&
      a.bottom >= b.top - margin;

  List<PenStroke> _eraseArea(int page, double x, double y, double radius, double? prevX, double? prevY) {
    final pen = penFor(page);
    final move = _areaMove ??= _AreaMove(page);
    if (move.page != page) return const []; // hareket başka sayfada sürüyor
    final path = [
      if (prevX != null && prevY != null && prevX.isFinite && prevY.isFinite) InkPoint(x: prevX, y: prevY),
      InkPoint(x: x, y: y),
    ];
    final changed = <PenStroke>[];
    // Kaba ön eleme: silgi yolunun kutusu + yarıçap + çizgi yarı kalınlığı çizgi kutusuyla kesişmiyorsa atla.
    final pathBox = ui.Rect.fromLTRB(
      path.map((p) => p.x).reduce(math.min) - radius,
      path.map((p) => p.y).reduce(math.min) - radius,
      path.map((p) => p.x).reduce(math.max) + radius,
      path.map((p) => p.y).reduce(math.max) + radius,
    );
    for (final s in List.of(pen._shown)) {
      if (!_boxesTouch(pathBox, s.bounds, brushHalfWidth(s.brush))) continue;
      final obj = InkObject(id: 'x', points: s.points, brush: s.brush);
      final res = eraseArea(obj, path, radius, idFor: (b, i) => '$b/$i');
      if (!res.changed) continue;
      final news = [for (final p in res.pieces) PenStroke(p.brush, p.points, layer: s.layer)..startedAtMs = s.startedAtMs];
      if (move.pieces.remove(s)) {
        // Hareketin kendi parçası: yalnız bellekte, kaydı yok.
      } else {
        s.erased = true;
        if (s.id != null) _pendingErase.add(s.id!);
        move.originals.add(s);
      }
      move.pieces.addAll(news);
      pen._replaceOne(s, news);
      changed.add(s);
    }
    return changed;
  }

  NewStroke _newStroke(int page, PenStroke p) => NewStroke(
    owner: _owner(page),
    points: _toRecord(p.points),
    startedAtMs: p.startedAtMs,
    layer: p.layer,
    tag: strokeTag,
    attemptNo: attemptNo,
    questionId: questionId,
    tool: toolColumnOf(p.brush),
    color: p.brush.color,
    width: p.brush.width,
  );

  /// Alan silgisi hareketi bitti: parçalar eklenir, özgünler yumuşak silinir (tek işlem, tek geri al kaydı).
  void _commitArea() {
    final move = _areaMove;
    _areaMove = null;
    if (move == null || (move.originals.isEmpty && move.pieces.isEmpty)) return;
    unawaited(
      _enqueue(() async {
        // Kaydı hiç yazılmamış (id'siz) özgünler: kayıt kuyruğu silindiği için atladı.
        // Önce eklenip aynı işlemde yumuşak silinir; geri al onları da getirir.
        final pending = [
          for (final s in move.originals)
            if (s.id == null) s,
        ];
        final ids = [
          for (final s in move.originals)
            if (s.id != null) s.id!,
        ];
        var added = const <String>[];
        var archived = const <String>[];
        final ok = await _try(() async {
          final r = await repository.replaceDetailed(
            deleteIds: ids,
            adds: [for (final p in move.pieces) _newStroke(move.page, p)],
            archive: [for (final s in pending) _newStroke(move.page, s)],
          );
          added = r.added;
          archived = r.archived;
        });
        _pendingErase.removeAll(ids);
        final pen = _pens[move.page];
        if (!ok) {
          // Hiçbir şey yazılmadı (işlem geri sarıldı): parçalar çıkar, özgünler geri konur.
          if (pen != null && !pen._disposed) {
            pen._removeWhere(move.pieces.contains);
            for (final s in move.originals) {
              s.erased = false;
              pen._add(s);
            }
          } else {
            for (final s in move.originals) {
              s.erased = false;
            }
          }
          // Kaydı bekleyenler yeniden kuyruğa: kalıcı kayıt olmadan kaybolmasınlar.
          for (final s in pending) {
            await _save(move.page, s);
          }
          _report('Silme kaydedilemedi; çizgiler geri konuldu.');
          return;
        }
        for (var i = 0; i < move.pieces.length; i++) {
          move.pieces[i].id = added[i];
        }
        for (var i = 0; i < pending.length; i++) {
          pending[i].id = archived[i];
          _failed.remove(pending[i]);
          _failedPage.remove(pending[i]);
        }
        _history.push(InkAction(InkActionKind.replaced, move.page, [...ids, ...archived], addedIds: added));
        _ping();
      }),
    );
  }

  /// Silgi hareketi bitti: kaldırılan çizgileri yumuşak siler (geri alınabilir).
  /// Kayıt başarısızsa çizgiler ekrana geri konur.
  void commitErase(int page, List<PenStroke> removed) {
    if (_areaMove != null) return _commitArea();
    if (removed.isEmpty) return;
    unawaited(
      _enqueue(() async {
        // Kaydı hiç yazılmamış (id'siz) çizgiler: kayıt kuyruğu silindiği için atladı.
        // Önce eklenip aynı işlemde yumuşak silinir; geri al onları da getirir.
        final pending = [
          for (final s in removed)
            if (s.id == null) s,
        ];
        final ids = [
          for (final s in removed)
            if (s.id != null) s.id!,
        ];
        var archived = const <String>[];
        final ok =
            (ids.isEmpty && pending.isEmpty) ||
            await _try(() async {
              if (pending.isEmpty) {
                await repository.softDeleteMany(ids);
              } else {
                final r = await repository.replaceDetailed(
                  deleteIds: ids,
                  adds: const [],
                  archive: [for (final s in pending) _newStroke(page, s)],
                );
                archived = r.archived;
              }
            });
        _pendingErase.removeAll(ids);
        if (!ok) {
          final pen = _pens[page];
          for (final s in removed) {
            s.erased = false;
            if (pen != null && !pen._disposed) pen._add(s);
          }
          // Kaydı atlanmış çizgiler yeniden kuyruğa: kalıcı kayıt olmadan kaybolmasınlar.
          for (final s in pending) {
            await _save(page, s);
          }
          _report('Silme kaydedilemedi; çizgiler geri konuldu.');
          return;
        }
        for (var i = 0; i < pending.length; i++) {
          pending[i].id = archived[i];
          _failed.remove(pending[i]);
          _failedPage.remove(pending[i]);
        }
        if (pending.isEmpty) {
          _history.push(InkAction(InkActionKind.erased, page, ids));
        } else {
          _history.push(InkAction(InkActionKind.replaced, page, [...ids, ...archived]));
        }
        _ping();
      }),
    );
  }

  Future<void> undo() => _enqueue(() async {
    if (_erasing) return;
    clearSelection();
    final a = _history.takeUndo();
    if (a == null) return;
    var gone = false;
    if (!await _try(() async => gone = !await _apply(a, forward: false))) {
      _history.returnUndo(a);
      _report('Geri alınamadı.');
      _ping();
      return;
    }
    if (gone) {
      // Çizgiler artık yok (kalıcı hata): eylem düşer, eski geri alınlar kilitlenmez.
      _report('Bu işlem geri alınamadı: çizgiler artık yok. Eylem listeden düşürüldü.');
      _ping();
      return;
    }
    _history.commitUndo(a);
    _ping();
  });

  Future<void> redo() => _enqueue(() async {
    if (_erasing) return;
    clearSelection();
    final a = _history.takeRedo();
    if (a == null) return;
    var gone = false;
    if (!await _try(() async => gone = !await _apply(a, forward: true))) {
      _history.returnRedo(a);
      _report('Yinelenemedi.');
      _ping();
      return;
    }
    if (gone) {
      _report('Bu işlem yinelenemedi: çizgiler artık yok. Eylem listeden düşürüldü.');
      _ping();
      return;
    }
    _history.commitRedo(a);
    _ping();
  });

  /// [forward]: eylemi (yeniden) uygula; değilse tersini. Tekrarlanabilir (idempotent).
  /// false: eylemin çizgilerinin HİÇBİRİ artık yok (kalıcı durum; yeniden denemek boşuna).
  Future<bool> _apply(InkAction a, {required bool forward}) async {
    if (a.kind == InkActionKind.updated) {
      // İleri: sonraki noktalar, geri: önceki noktalar; yerinde yazılır, tek işlem.
      var pts = (forward ? a.after : a.before)!;
      try {
        await repository.updatePoints({for (final e in pts.entries) e.key: _toRecord(e.value)});
      } on MissingStrokeError {
        // Bazı çizgiler yok (örn. dışarıdan silindi): olanları tek tek yaz, olmayanları atla.
        final done = <String, List<InkPoint>>{};
        for (final e in pts.entries) {
          try {
            await repository.updatePoints({e.key: _toRecord(e.value)});
            done[e.key] = e.value;
          } on MissingStrokeError {
            // atla
          }
        }
        if (done.isEmpty) return false;
        pts = done;
      }
      _applyPoints(a.page, pts);
      return true;
    }
    if (a.kind == InkActionKind.replaced) {
      // İleri: özgünler silinir, parçalar gelir. Geri: tersi. Tek işlem.
      await repository.swap(
        deleteIds: forward ? a.strokeIds : a.addedIds,
        restoreIds: forward ? a.addedIds : a.strokeIds,
      );
      final pen = _pens[a.page];
      if (pen != null) await _load(pen);
      return true;
    }
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
    return true;
  }

  void _ping() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _nearTimer?.cancel();
    _overlay?.dispose();
    viewerLocked.dispose();
    selectionTick.dispose();
    zoomInteraction.dispose();
    _errors.close();
    for (final p in _pens.values) {
      p.dispose();
    }
    _pens.clear();
    super.dispose();
  }
}
