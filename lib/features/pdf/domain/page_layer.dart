/// PDF katmanları (saf Dart). Katman = PDF sayfalarının üstünde kalemin yazdığı ŞEFFAF
/// ÇİZİM katmanı. PDF dosyası değişmez. Tablo: `pdf_page_layers` (yeni anlam):
/// `kind` 'full' (tüm sayfalar) | 'question' (tek sayfada bir bölge). Eski 'watermark' /
/// 'cover' satırları yok sayılır (silinmez). Çizgiler `ink_strokes.layer` = katman numarası.
library;

import 'dart:convert';
import 'dart:ui' show Offset;

import 'pdf_engine.dart' show PdfBox;

enum PdfLayerKind {
  full('full', 'Tam sayfa'),
  question('question', 'Soru bölgesi');

  const PdfLayerKind(this.key, this.label);
  final String key;
  final String label;

  /// Bilinmeyen (eski 'watermark'/'cover') için null.
  static PdfLayerKind? parse(String s) {
    for (final k in values) {
      if (k.key == s) return k;
    }
    return null;
  }
}

/// Tam sayfa katmanın `page` değeri.
const int allPdfPages = -1;

/// Ana çizim (katmansız eski çizgiler): numarasız katman 0.
const int mainInkLayer = 0;

/// `ink_strokes.noteId` ayırıcısı: katman penceresinin çizgileri.
String layerWindowTag(String layerId) => 'katman-pencere:$layerId';

/// Katman parametreleri (`params` JSON). Varsayılanlar eski örtü kodundakiyle aynı.
class PdfPageLayer {
  const PdfPageLayer({
    required this.id,
    required this.documentId,
    required this.page,
    required this.kind,
    this.box,
    this.params = const {},
    this.z = 0,
    this.name = '',
    this.visible = true,
    this.deleted = false,
    this.number = 0,
  });

  final String id;
  final String documentId;

  /// 0'dan; [allPdfPages] = tüm sayfalar.
  final int page;
  final PdfLayerKind kind;

  /// Soru katmanı: PDF sayfa birimi (sol-üst, y aşağı); tam sayfada null.
  final PdfBox? box;
  final Map<String, Object?> params;
  final int z;
  final String name;
  final bool visible;
  final bool deleted;

  /// GÖRÜNTÜ numarası: silinmeyenler arasında görüntü sırasına göre 1..n; [orderLayers] atar.
  /// Silme/sıra değişince kayar; çizgiler bunu DEĞİL [key]'i kullanır.
  final int number;

  /// KALICI anahtar (`ink_strokes.layer`): `z + 1`. Silme ve sıra değişimi bunu değiştirmez
  /// (0 = ana çizim).
  int get key => z + 1;

  /// Görüntü sırası (gezinme/numaralama): `params['order']`, yoksa [z].
  int get order => params['order'] is num ? (params['order'] as num).toInt() : z;

  bool get isQuestion => kind == PdfLayerKind.question && box != null;

  /// Bu katmanın bu sayfada çizimi var mı.
  bool appliesTo(int p) => !deleted && (page == allPdfPages || page == p);

  double get opacity => params['opacity'] is num ? (params['opacity'] as num).toDouble().clamp(0, 1).toDouble() : 1.0;
  int get color => params['color'] is num ? (params['color'] as num).toInt() : 0xFFFFFFFF;

  /// Katmana özel kalınlık; null = araç kalınlığı.
  double? get width => params['width'] is num ? (params['width'] as num).toDouble() : null;
  String get note => params['note'] is String ? params['note'] as String : '';
  bool get noteOpen => params['noteOpen'] == true;

  /// Küçük düğmenin konumu (PDF sayfa birimi, [page] sayfasında); yoksa null.
  Offset? get buttonAt {
    final x = params['buttonX'], y = params['buttonY'];
    return x is num && y is num ? Offset(x.toDouble(), y.toDouble()) : null;
  }

  /// Düğmenin varsayılan yeri: bölgenin sağ üstünün hemen dışı.
  Offset get defaultButtonAt => box == null ? Offset.zero : Offset(box!.right + 6, box!.top);

  PdfPageLayer withParams(Map<String, Object?> patch, {int? number}) => PdfPageLayer(
        id: id,
        documentId: documentId,
        page: page,
        kind: kind,
        box: box,
        params: {...params, ...patch},
        z: z,
        name: name,
        visible: visible,
        deleted: deleted,
        number: number ?? this.number,
      );

  static Map<String, Object?> decodeParams(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map ? v.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// Silinmemiş katmanları GÖRÜNTÜ sırasıyla ([PdfPageLayer.order], sonra z, kimlik) dizer ve
/// 1'den numaralar.
List<PdfPageLayer> orderLayers(Iterable<PdfPageLayer> all) {
  final l = [for (final x in all) if (!x.deleted) x];
  l.sort((a, b) {
    if (a.order != b.order) return a.order.compareTo(b.order);
    if (a.z != b.z) return a.z.compareTo(b.z);
    return a.id.compareTo(b.id);
  });
  return [for (var i = 0; i < l.length; i++) l[i].withParams(const {}, number: i + 1)];
}

/// Görüntü numarası -> kalıcı çizgi anahtarı ([PdfPageLayer.key]); 0 (ana çizim) ya da
/// bulunamayan numara için 0.
int layerKeyForNumber(List<PdfPageLayer> layers, int number) {
  for (final l in layers) {
    if (l.number == number) return l.key;
  }
  return mainInkLayer;
}

/// Kalıcı çizgi anahtarı -> görüntü numarası; bilinmeyen (silinmiş) anahtar için null.
/// 0 (ana çizim) -> 0.
int? layerNumberForKey(List<PdfPageLayer> layers, int key) {
  if (key == mainInkLayer) return 0;
  for (final l in layers) {
    if (l.key == key) return l.number;
  }
  return null;
}

/// [number]. katmanı [delta] kadar kaydırınca (-1 öne, +1 arkaya) her katmanın yeni
/// `order` değeri (kimlik -> sıra, 0'dan). Sınır dışıysa null. Yalnız `order` değişir;
/// `z` (çizgi anahtarı) dokunulmaz.
Map<String, int>? moveLayerOrders(List<PdfPageLayer> ordered, int number, int delta) {
  final i = number - 1, j = i + delta;
  if (i < 0 || i >= ordered.length || j < 0 || j >= ordered.length) return null;
  final ids = [for (final l in ordered) l.id];
  final id = ids.removeAt(i);
  ids.insert(j, id);
  return {for (var k = 0; k < ids.length; k++) ids[k]: k};
}

/// [p] (sayfa birimi) soru katmanının bölgesinde mi.
bool layerAccepts(PdfPageLayer? layer, int page, Offset p) {
  if (layer == null || layer.deleted) return true; // ana çizim / bilinmeyen
  if (layer.kind == PdfLayerKind.full) return true;
  final b = layer.box;
  if (b == null || layer.page != page) return false;
  return p.dx >= b.left && p.dx <= b.right && p.dy >= b.top && p.dy <= b.bottom;
}
