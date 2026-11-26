import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../data/ink_page_item_repository.dart';
import '../domain/page_board.dart';
import '../domain/page_item_geometry.dart';
import 'text_item_widget.dart';

/// Bir sayfanın metin kutusu ve görsel öğelerinin ekran durumu: veritabanı akışı +
/// yerel (iyimser) değişiklikler + seçim/düzenleme. Yazmalar depoya gider; hata olursa
/// yerel değişiklik geri alınır ve [onError] iletilir. Veritabanı akışı gelene kadar
/// yeni eklenen öğeler "bekleyen" olarak gösterilir.
class PageItemsController extends ChangeNotifier {
  PageItemsController({
    required this.repo,
    required this.pageId,
    required this.pageW,
    required this.pageH,
    this.onError,
    this.debounce = const Duration(milliseconds: 400),
  });

  final InkPageItemRepository repo;
  final String pageId;
  double pageW;
  double pageH;
  final void Function(String message)? onError;

  /// Yazılırken kaydetme gecikmesi.
  final Duration debounce;

  List<PageItemRecord> _stream = const [];
  final Map<String, PageItemRecord> _pending = {};
  final Map<String, _Local> _local = {};
  final Set<String> _hidden = {};
  String? _selected;
  String? _editing;
  final Map<String, Timer> _textTimers = {};
  bool _disposed = false;

  String? get selectedId => _selected;
  String? get editingId => _editing;

  PageItemRecord? get selected => _selected == null ? null : byId(_selected!);

  /// Görünen öğeler, alttan üste (z, sonra oluşturma sırası). Yerel değişiklikler ve
  /// içeriğe göre büyüyen metin yüksekliği uygulanmıştır.
  List<PageItemRecord> get items {
    final all = <PageItemRecord>[
      for (final it in _stream)
        if (!_hidden.contains(it.id) && it.kind != null) _applyLocal(it),
      for (final it in _pending.values)
        if (!_hidden.contains(it.id) && !_stream.any((s) => s.id == it.id)) _applyLocal(it),
    ];
    all.sort((a, b) {
      final c = a.z.compareTo(b.z);
      if (c != 0) return c;
      final d = a.createdAt.compareTo(b.createdAt);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
    return all;
  }

  PageItemRecord? byId(String id) {
    for (final it in items) {
      if (it.id == id) return it;
    }
    return null;
  }

  PageItemRecord _applyLocal(PageItemRecord it) {
    final l = _local[it.id];
    var r = it;
    if (l != null) {
      r = _copy(
        it,
        rect: l.rect,
        rotation: l.rotation,
        z: l.z,
        payloadJson: l.payloadJson,
      );
    }
    if (r.kind == PageItemKind.text) {
      final need = measureTextHeight(r.text, r.w);
      if (need > r.h + 0.01) r = _copy(r, rect: BoardRect(r.x, r.y, r.w, need));
    }
    return r;
  }

  /// Veritabanı akışı geldi.
  void sync(List<PageItemRecord> stream) {
    _stream = stream;
    final ids = {for (final s in stream) s.id};
    _pending.removeWhere((id, _) => ids.contains(id));
    _hidden.removeWhere((id) => !ids.contains(id) && !_pending.containsKey(id));
    // Yazması bitmiş yerel değişiklikler akışa geçti: bırak.
    _local.removeWhere((_, l) => l.committed);
    if (_selected != null && byId(_selected!) == null) {
      _selected = null;
      _editing = null;
    }
    _notify();
  }

  void select(String? id) {
    if (_selected == id) return;
    if (_editing != null && _editing != id) unawaited(stopEditing());
    _selected = id;
    _notify();
  }

  /// Seçili metin kutusunu düzenlemeye açar (klavye açılır).
  void startEditing(String id) {
    final it = byId(id);
    if (it == null || it.kind != PageItemKind.text) return;
    if (_editing != null && _editing != id) unawaited(stopEditing());
    _selected = id;
    _editing = id;
    _notify();
  }

  /// Düzenlemeyi bitirir: bekleyen yazı kaydedilir, yüksekliği içeriğe uydurulur;
  /// boş kalan kutu (yeni eklenip yazılmamış) sessizce silinir.
  Future<void> stopEditing() async {
    final id = _editing;
    if (id == null) return;
    _editing = null;
    _notify();
    await _flushText(id);
    final it = byId(id);
    if (it == null) return;
    if (it.text.text.trim().isEmpty) {
      await _softDelete(id, quiet: true);
      return;
    }
    // Yükseklik içeriğe uysun (kayıtlı kutu en az bu kadar).
    final stored = _stream.where((s) => s.id == id).firstOrNull ?? _pending[id];
    if (stored != null && (it.h - stored.h).abs() > 0.5) {
      await commitGeometry(id, rect: it.rect);
    }
  }

  // ───────────── oluştur ─────────────

  /// ([x],[y]) noktasında boş metin kutusu açar ve düzenlemeye başlar. Kimliği döner.
  Future<String?> createText(double x, double y, {int color = 0xFF000000}) async {
    final payload = TextItemPayload(color: color);
    const w = 360.0;
    final rect = clampItemRect(BoardRect(x - 12, y - 12, w, measureTextHeight(payload.copyWith(text: ' '), w)), pageW, pageH);
    try {
      final id = await repo.addText(pageId, rect, payload: payload);
      if (_disposed) return id;
      final now = DateTime.now();
      _pending[id] = PageItemRecord(
        id: id,
        pageId: pageId,
        kind: PageItemKind.text,
        x: rect.x,
        y: rect.y,
        w: rect.w,
        h: rect.h,
        rotation: 0,
        z: _topZ() + 1,
        payloadJson: payload.toJson(),
        mediaPath: null,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      );
      startEditing(id);
      return id;
    } catch (e) {
      onError?.call('Metin kutusu eklenemedi: ${_msg(e)}');
      return null;
    }
  }

  /// Kaydedilmiş görseli ([mediaPath]) [rect] kutusuna ekler ve seçer. Kimliği döner.
  Future<String?> addImage(String mediaPath, BoardRect rect, ImageItemPayload payload) async {
    try {
      final id = await repo.addImage(pageId, rect, mediaPath, payload: payload);
      if (_disposed) return id;
      final now = DateTime.now();
      _pending[id] = PageItemRecord(
        id: id,
        pageId: pageId,
        kind: PageItemKind.image,
        x: rect.x,
        y: rect.y,
        w: rect.w,
        h: rect.h,
        rotation: 0,
        z: _topZ() + 1,
        payloadJson: payload.toJson(),
        mediaPath: mediaPath,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      );
      _selected = id;
      _notify();
      return id;
    } catch (e) {
      onError?.call('Görsel eklenemedi: ${_msg(e)}');
      return null;
    }
  }

  int _topZ() {
    var m = -1;
    for (final it in items) {
      if (it.z > m) m = it.z;
    }
    return m;
  }

  int _bottomZ() {
    var m = 0;
    for (final it in items) {
      if (it.z < m) m = it.z;
    }
    return m;
  }

  // ───────────── geometri ─────────────

  /// Sürükleme sırasında yalnız ekranda önizler (yazılmaz).
  void preview(String id, {BoardRect? rect, double? rotation}) {
    final it = byId(id);
    if (it == null) return;
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    l.committed = false;
    if (rect != null) l.rect = rect;
    if (rotation != null) l.rotation = rotation;
    _notify();
  }

  /// Önizlenen (ya da verilen) geometriyi yazar. Hata olursa eski haline döner.
  Future<void> commitGeometry(String id, {BoardRect? rect, double? rotation}) async {
    final it = byId(id);
    if (it == null) return;
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    if (rect != null) l.rect = rect;
    if (rotation != null) l.rotation = rotation;
    l.committed = false;
    final r = l.rect, rot = l.rotation;
    _notify();
    try {
      await repo.updateGeometry(id, rect: r, rotation: rot);
      l.committed = true;
    } catch (e) {
      _local.remove(id);
      _notify();
      onError?.call('Öğe kaydedilemedi: ${_msg(e)}');
    }
  }

  /// Öğeyi diğerlerinin üstüne alır.
  Future<void> bringToFront(String id) async {
    final it = byId(id);
    if (it == null) return;
    final top = _topZ();
    if (it.z >= top && items.where((o) => o.id != id && o.z == it.z).isEmpty) return;
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    l.z = top + 1;
    l.committed = false;
    _notify();
    try {
      await repo.bringToFront(id);
      l.committed = true;
    } catch (e) {
      _local.remove(id);
      _notify();
      onError?.call('Öne alınamadı: ${_msg(e)}');
    }
  }

  /// Öğeyi diğerlerinin arkasına alır.
  Future<void> sendToBack(String id) async {
    final it = byId(id);
    if (it == null) return;
    final z = _bottomZ() - 1;
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    l.z = z;
    l.committed = false;
    _notify();
    try {
      await repo.updateGeometry(id, z: z);
      l.committed = true;
    } catch (e) {
      _local.remove(id);
      _notify();
      onError?.call('Arkaya alınamadı: ${_msg(e)}');
    }
  }

  // ───────────── içerik ─────────────

  /// Metin değişti (her tuşta): ekranda hemen, kayıt [debounce] sonra.
  void setText(String id, TextItemPayload payload) {
    final it = byId(id);
    if (it == null || it.kind != PageItemKind.text) return;
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    l.payloadJson = payload.toJson();
    l.committed = false;
    _textTimers[id]?.cancel();
    _textTimers[id] = Timer(debounce, () => unawaited(_flushText(id)));
    _notify();
  }

  /// Biçim değişikliği (boyut/renk/kalın/italik/hizalama): hemen kaydedilir.
  Future<void> setTextNow(String id, TextItemPayload payload) async {
    setText(id, payload);
    await _flushText(id);
  }

  Future<void> _flushText(String id) async {
    _textTimers.remove(id)?.cancel();
    final l = _local[id];
    if (l == null || l.committed) return;
    final json = l.payloadJson;
    try {
      await repo.updateText(id, TextItemPayload.fromJson(json));
      if (l.payloadJson == json) l.committed = true;
    } catch (e) {
      onError?.call('Yazı kaydedilemedi: ${_msg(e)}');
    }
  }

  Future<void> setImageAlpha(String id, double alpha, {bool persist = true}) async {
    final it = byId(id);
    if (it == null || it.kind != PageItemKind.image) return;
    final p = it.image.copyWith(alpha: alpha.clamp(0.0, 1.0).toDouble());
    final l = _local.putIfAbsent(id, () => _Local.from(it));
    l.payloadJson = p.toJson();
    l.committed = false;
    _notify();
    if (!persist) return;
    try {
      await repo.updateImage(id, p);
      l.committed = true;
    } catch (e) {
      _local.remove(id);
      _notify();
      onError?.call('Saydamlık kaydedilemedi: ${_msg(e)}');
    }
  }

  // ───────────── sil / kopyala ─────────────

  /// Yumuşak siler (görsel DOSYASI silinmez). Geri almak için [restore].
  Future<bool> delete(String id) => _softDelete(id, quiet: false);

  Future<bool> _softDelete(String id, {required bool quiet}) async {
    if (byId(id) == null) return false;
    _textTimers.remove(id)?.cancel();
    _hidden.add(id);
    if (_selected == id) _selected = null;
    if (_editing == id) _editing = null;
    _notify();
    try {
      await repo.deleteItem(id);
      return true;
    } catch (e) {
      _hidden.remove(id);
      _notify();
      if (!quiet) onError?.call('Öğe silinemedi: ${_msg(e)}');
      return false;
    }
  }

  Future<void> restore(String id) async {
    try {
      await repo.restoreItem(id);
      _hidden.remove(id);
      _selected = id;
      _notify();
    } catch (e) {
      onError?.call('Geri alınamadı: ${_msg(e)}');
    }
  }

  /// Öğenin kopyasını biraz kaydırarak ekler ve seçer (görsel dosyası paylaşılır).
  Future<String?> duplicate(String id) async {
    final it = byId(id);
    if (it == null) return null;
    final moved = clampItemRect(BoardRect(it.x + 24, it.y + 24, it.w, it.h), pageW, pageH);
    try {
      final String nid;
      if (it.kind == PageItemKind.text) {
        nid = await repo.addText(pageId, moved, payload: it.text, rotation: it.rotation);
      } else {
        nid = await repo.addImage(pageId, moved, it.mediaPath!, payload: it.image, rotation: it.rotation);
      }
      if (_disposed) return nid;
      final now = DateTime.now();
      _pending[nid] = PageItemRecord(
        id: nid,
        pageId: pageId,
        kind: it.kind,
        x: moved.x,
        y: moved.y,
        w: moved.w,
        h: moved.h,
        rotation: it.rotation,
        z: _topZ() + 1,
        payloadJson: it.payloadJson,
        mediaPath: it.mediaPath,
        deleted: false,
        createdAt: now,
        updatedAt: now,
      );
      _selected = nid;
      _notify();
      return nid;
    } catch (e) {
      onError?.call('Kopyalanamadı: ${_msg(e)}');
      return null;
    }
  }

  /// Bekleyen yazıları yazar (sayfa kapanırken).
  Future<void> flush() async {
    for (final id in _textTimers.keys.toList()) {
      await _flushText(id);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _msg(Object e) => e is StateError ? e.message : (e is ArgumentError ? '${e.message}' : '$e');

  @override
  void dispose() {
    _disposed = true;
    // Bekleyen yazıyı kaybetme: zamanlayıcılar iptal, yazma hemen başlatılır.
    final ids = _textTimers.keys.toList();
    for (final t in _textTimers.values) {
      t.cancel();
    }
    _textTimers.clear();
    for (final id in ids) {
      final l = _local[id];
      if (l != null && !l.committed) {
        unawaited(repo.updateText(id, TextItemPayload.fromJson(l.payloadJson)).catchError((_) {}));
      }
    }
    super.dispose();
  }
}

class _Local {
  _Local(this.rect, this.rotation, this.z, this.payloadJson);
  factory _Local.from(PageItemRecord it) => _Local(it.rect, it.rotation, it.z, it.payloadJson);
  BoardRect rect;
  double rotation;
  int z;
  String payloadJson;

  /// Yazma bitti: sonraki akış geldiğinde yerel kayıt bırakılır.
  bool committed = false;
}

PageItemRecord _copy(PageItemRecord it, {BoardRect? rect, double? rotation, int? z, String? payloadJson}) => PageItemRecord(
      id: it.id,
      pageId: it.pageId,
      kind: it.kind,
      x: rect?.x ?? it.x,
      y: rect?.y ?? it.y,
      w: rect?.w ?? it.w,
      h: rect?.h ?? it.h,
      rotation: rotation ?? it.rotation,
      z: z ?? it.z,
      payloadJson: payloadJson ?? it.payloadJson,
      mediaPath: it.mediaPath,
      deleted: it.deleted,
      createdAt: it.createdAt,
      updatedAt: it.updatedAt,
    );

const maxItemFont = 160.0;
const minItemFont = 8.0;
double clampFont(double v) => math.min(maxItemFont, math.max(minItemFont, v));
