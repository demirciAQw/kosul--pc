import 'dart:async';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../notes/data/note_tool_prefs_store.dart';
import '../data/pdf_layers_repository.dart';
import '../domain/page_layer.dart';
import '../domain/pdf_engine.dart' show PdfBox;

/// Bir PDF'in katman durumu (tek kaynak): katman listesi, aktif katman, "tek tıkla
/// eklenecek tür", "numarayı göster", bölge seçim modu ve yuvarlak bölge düğmesinin
/// konumu/görünürlüğü. Üst çubuk düğmesi, soldaki gezinme hapı, bölge düğmesi, soru katmanı
/// küçük düğmeleri ve katman penceresi bunu paylaşır.
///
/// [active] GÖRÜNTÜ numarasıdır (silme/sıra değişimiyle kayar); çizgiler ise [activeKey]
/// (kalıcı anahtar, `PdfPageLayer.key`) ile saklanır.
class PdfLayerState extends ChangeNotifier {
  PdfLayerState({required this.documentId, required this.repository, required this.prefs, required this.regionPrefs});

  final String documentId;
  final PdfLayersRepository repository;
  final NoteToolPrefsStore prefs;

  /// Bölge düğmesinin konumu ve gizli bayrağı (`pdf.bolge_dugmesi`): tüm PDF'lerde ortak.
  final NoteToolPrefsStore regionPrefs;

  List<PdfPageLayer> _layers = const [];
  int _active = mainInkLayer;
  PdfLayerKind _addType = PdfLayerKind.full;
  bool _showNumber = true;
  bool _selecting = false;
  bool _regionVisible = true;
  Offset? _regionAt; // ekran oranı (0..1); null = varsayılan
  bool _loaded = false;
  bool _disposed = false;
  Timer? _noteTimer;
  final Map<String, Map<String, Object?>> _pendingNotes = {};

  /// Numaralı, sıralı katmanlar (1'den). Ana çizim (0) listede yok.
  List<PdfPageLayer> get layers => _layers;

  /// Aktif katman numarası; 0 = ana çizim.
  int get active => _active;
  PdfLayerKind get addType => _addType;
  bool get showNumber => _showNumber;

  /// Soru katmanı için PDF üzerinde bölge sürükleme bekleniyor.
  bool get selecting => _selecting;
  bool get loaded => _loaded;

  PdfPageLayer? byNumber(int n) {
    for (final l in _layers) {
      if (l.number == n) return l;
    }
    return null;
  }

  PdfPageLayer? get activeLayer => byNumber(_active);

  /// Aktif katmanın KALICI çizgi anahtarı (`ink_strokes.layer`); ana çizim için 0.
  int get activeKey => layerKeyForNumber(_layers, _active);

  /// Bölge seçme düğmesi görünsün mü (kalıcı).
  bool get regionButtonVisible => _regionVisible;

  /// Düğmenin kayıtlı konumu (serbest alanın oranı, 0..1); null = varsayılan.
  Offset? get regionButtonAt => _regionAt;

  PdfPageLayer? byKey(int key) {
    for (final l in _layers) {
      if (l.key == key) return l;
    }
    return null;
  }

  PdfPageLayer? byId(String id) {
    for (final l in _layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Bu sayfada küçük düğmesi görünecek soru katmanları.
  List<PdfPageLayer> questionLayersOn(int page) => [
        for (final l in _layers)
          if (l.isQuestion && l.page == page) l,
      ];

  /// Oturumun çizgi süzgeci: soru katmanında bölge dışına başlayan çizgi çizilmez.
  bool accepts(int page, int layerKey, Offset pagePoint) => layerAccepts(byKey(layerKey), page, pagePoint);

  Future<void> load() async {
    try {
      final m = await prefs.load();
      _addType = m['tur'] == 'question' ? PdfLayerKind.question : PdfLayerKind.full;
      _showNumber = m['numara'] != false;
    } catch (_) {}
    try {
      final r = await regionPrefs.load();
      _regionVisible = r['gizli'] != true;
      final x = r['x'], y = r['y'];
      _regionAt = x is num && y is num ? Offset(x.toDouble().clamp(0.0, 1.0), y.toDouble().clamp(0.0, 1.0)) : null;
    } catch (_) {}
    await refresh();
    if (!_loaded) {
      _loaded = true;
      if (_layers.isNotEmpty) _active = _layers.last.number;
      _notify();
    }
  }

  Future<void> refresh() async {
    try {
      final l = await repository.all(documentId);
      if (_disposed) return;
      _layers = l;
      if (_active > l.length) _active = l.length;
      _notify();
    } catch (_) {
      // veritabanı kapanmış olabilir
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _savePrefs() async {
    try {
      await prefs.save({'tur': _addType.key, 'numara': _showNumber});
    } catch (_) {}
  }

  void setAddType(PdfLayerKind k) {
    if (_addType == k) return;
    _addType = k;
    _notify();
    unawaited(_savePrefs());
  }

  Future<void> _saveRegion() async {
    try {
      await regionPrefs.save({
        if (_regionAt != null) 'x': _regionAt!.dx,
        if (_regionAt != null) 'y': _regionAt!.dy,
        'gizli': !_regionVisible,
      });
    } catch (_) {}
  }

  void setRegionVisible(bool v) {
    if (_regionVisible == v) return;
    _regionVisible = v;
    if (!v) _selecting = false;
    _notify();
    unawaited(_saveRegion());
  }

  /// Bölge düğmesinin yeni konumu (serbest alanın oranı); kalıcı.
  void setRegionAt(Offset ratio) {
    _regionAt = Offset(ratio.dx.clamp(0.0, 1.0), ratio.dy.clamp(0.0, 1.0));
    _notify();
    unawaited(_saveRegion());
  }

  void setShowNumber(bool v) {
    if (_showNumber == v) return;
    _showNumber = v;
    _notify();
    unawaited(_savePrefs());
  }

  void setSelecting(bool v) {
    if (_selecting == v) return;
    _selecting = v;
    _notify();
  }

  void setActive(int n) {
    if (n < 0 || n > _layers.length || n == _active) return;
    _active = n;
    _notify();
  }

  /// Yeni boş tam sayfa katman ekler ve aktif yapar.
  Future<PdfPageLayer?> addFull() => _add(PdfLayerKind.full, allPdfPages, null);

  /// Yeni soru katmanı ([page] 0'dan, [box] PDF sayfa birimi) ekler ve aktif yapar.
  Future<PdfPageLayer?> addQuestion(int page, PdfBox box) => _add(PdfLayerKind.question, page, box);

  /// Aynı bölgeye yeni katman (küçük düğme menüsü); düğmesi eskisinden biraz aşağıda doğar.
  Future<PdfPageLayer?> addLike(PdfPageLayer src) {
    final b = src.box;
    if (b == null) return addFull();
    return _add(PdfLayerKind.question, src.page, b, button: (src.buttonAt ?? src.defaultButtonAt) + const Offset(0, 40));
  }

  Future<PdfPageLayer?> _add(PdfLayerKind kind, int page, PdfBox? box, {Offset? button}) async {
    try {
      final id = await repository.add(
        documentId: documentId,
        page: page,
        kind: kind,
        box: box,
        params: {if (button != null) 'buttonX': button.dx, if (button != null) 'buttonY': button.dy},
        name: 'Katman ${_layers.length + 1}',
      );
      await refresh();
      final l = byId(id);
      if (l != null) _active = l.number;
      _notify();
      return l;
    } catch (_) {
      return null;
    }
  }

  /// Üst çubuktaki tek tıklama: seçili türde ekler. Soru ise bölge seçimini başlatır (false döner).
  Future<bool> addByPreference() async {
    if (_addType == PdfLayerKind.question) {
      setSelecting(true);
      return false;
    }
    return await addFull() != null;
  }

  /// Soldaki hap, ◀: bir önceki katmana (ilk katmandan ana çizime) geç.
  void prev() {
    if (_active > 0) setActive(_active - 1);
  }

  /// Soldaki hap, ▶ / "+": sıradaki katmana geç; sondaysa (ya da katman yoksa) yenisini ekle.
  Future<void> next() async {
    if (_layers.isNotEmpty && _active < _layers.length) {
      setActive(_active + 1);
    } else {
      await addByPreference();
    }
  }

  /// Katmanı YUMUŞAK siler (çizgiler silinmez, yalnız gizlenir). Aktif katman silinirse bir
  /// öncekine geçilir. Geri almak için [restoreLayer]. Silinen katmanı döner.
  Future<PdfPageLayer?> deleteLayer(int number) async {
    final l = byNumber(number);
    if (l == null) return null;
    try {
      await repository.setDeleted(l.id, true);
    } catch (_) {
      return null;
    }
    if (number == _active) {
      _active = number - 1;
    } else if (number < _active) {
      _active -= 1;
    }
    await refresh();
    return l;
  }

  /// Silinen katmanı geri getirir ve aktif yapar.
  Future<void> restoreLayer(String id) async {
    try {
      await repository.setDeleted(id, false);
    } catch (_) {
      return;
    }
    await refresh();
    final l = byId(id);
    if (l != null) setActive(l.number);
  }

  /// [number]. katmanı görüntü sırasında [delta] kaydırır (-1 öne, +1 arkaya). Yalnız `order`
  /// değişir; çizgi anahtarı (z) sabit kalır. Aktif katman, taşınanı izler.
  Future<void> moveLayer(int number, int delta) async {
    final orders = moveLayerOrders(_layers, number, delta);
    final moved = byNumber(number);
    if (orders == null || moved == null) return;
    for (final l in _layers) {
      final o = orders[l.id];
      if (o == null || o == l.order) continue;
      try {
        await repository.setParams(l.id, {...l.params, 'order': o});
      } catch (_) {}
    }
    await refresh();
    final m = byId(moved.id);
    if (m != null) _active = m.number;
    _notify();
  }

  /// Küçük düğmenin yeni konumu (sayfa birimi); kalıcı.
  Future<void> setButtonAt(String id, Offset p) => _patch(id, {'buttonX': p.dx, 'buttonY': p.dy});

  Future<void> setNoteOpen(String id, bool open) => _patch(id, {'noteOpen': open});

  /// Notu ~500 ms gecikmeyle kaydeder (yazarken).
  void setNote(String id, String text) {
    final l = byId(id);
    if (l == null) return;
    _applyLocal(id, {'note': text});
    _pendingNotes[id] = {'note': text};
    _noteTimer?.cancel();
    _noteTimer = Timer(const Duration(milliseconds: 500), flushNotes);
  }

  Future<void> flushNotes() async {
    _noteTimer?.cancel();
    final p = Map.of(_pendingNotes);
    _pendingNotes.clear();
    for (final e in p.entries) {
      final l = byId(e.key);
      if (l != null) await repository.setParams(e.key, l.params);
    }
  }

  void _applyLocal(String id, Map<String, Object?> patch) {
    _layers = [for (final l in _layers) l.id == id ? l.withParams(patch) : l];
    _notify();
  }

  Future<void> _patch(String id, Map<String, Object?> patch) async {
    _applyLocal(id, patch);
    final l = byId(id);
    if (l != null) {
      try {
        await repository.setParams(id, l.params);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _noteTimer?.cancel();
    if (_pendingNotes.isNotEmpty) {
      final p = Map.of(_pendingNotes);
      _pendingNotes.clear();
      for (final id in p.keys) {
        final l = byId(id);
        if (l != null) unawaited(repository.setParams(id, l.params).catchError((Object _) => false));
      }
    }
    super.dispose();
  }
}
