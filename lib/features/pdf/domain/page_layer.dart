/// PDF görüntüleme katmanı (saf Dart). PDF dosyası değişmez; katmanlar yalnızca
/// görüntülemede uygulanır. Tablo: `pdf_page_layers`.
library;

import 'dart:convert';

import 'pdf_engine.dart' show PdfBox;
import 'watermark.dart';

enum PdfLayerKind {
  watermark('watermark', 'Filigran temizleme'),
  cover('cover', 'Örtü');

  const PdfLayerKind(this.key, this.label);
  final String key;
  final String label;

  static PdfLayerKind parse(String s) =>
      PdfLayerKind.values.firstWhere((k) => k.key == s, orElse: () => PdfLayerKind.cover);
}

/// Katmanın kapsamı (kullanıcıya gösterilen).
enum PdfLayerScope { thisPage, allPages, region, regionAllPages }

/// Tüm sayfalar için `page` değeri.
const int allPdfPages = -1;

/// Örtü ayarı: ARGB renk ve opaklık 0..1.
class CoverParams {
  const CoverParams({this.color = 0xFFFFFFFF, this.opacity = 1.0});
  final int color;
  final double opacity;

  Map<String, Object?> toJson() => {'color': color, 'opacity': opacity};

  factory CoverParams.fromJson(Map<String, Object?> j) => CoverParams(
        color: j['color'] is num ? (j['color'] as num).toInt() : 0xFFFFFFFF,
        opacity: j['opacity'] is num ? (j['opacity'] as num).toDouble().clamp(0, 1).toDouble() : 1.0,
      );
}

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
  });

  final String id;
  final String documentId;

  /// 0'dan; [allPdfPages] = tüm sayfalar.
  final int page;
  final PdfLayerKind kind;

  /// PDF sayfa birimi (sol-üst, y aşağı); null = tüm sayfa.
  final PdfBox? box;
  final Map<String, Object?> params;
  final int z;
  final String name;
  final bool visible;
  final bool deleted;

  bool get isAllPages => page == allPdfPages;
  bool appliesTo(int p) => !deleted && (page == allPdfPages || page == p);

  PdfLayerScope get scope {
    if (box != null) return isAllPages ? PdfLayerScope.regionAllPages : PdfLayerScope.region;
    return isAllPages ? PdfLayerScope.allPages : PdfLayerScope.thisPage;
  }

  WatermarkParams get watermark => WatermarkParams.fromJson(params);
  CoverParams get cover => CoverParams.fromJson(params);

  /// Görüntü önbelleği anahtarına giren her şey (kutu, parametre).
  String get paramKey => '${kind.key}|${box ?? '-'}|${jsonEncode(params)}';

  static Map<String, Object?> decodeParams(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map ? v.cast<String, Object?>() : const {};
    } catch (_) {
      return const {};
    }
  }
}

/// Sayfaya uygulanacak görünür katmanlar, z sırasıyla (küçük = alt); eşitlikte kimlik.
List<PdfPageLayer> visibleLayersFor(Iterable<PdfPageLayer> all, int page) {
  final l = [for (final x in all) if (x.visible && x.appliesTo(page)) x];
  l.sort((a, b) => a.z != b.z ? a.z.compareTo(b.z) : a.id.compareTo(b.id));
  return l;
}

/// Katman kutusunu sayfa sınırına kırpar; sayfayla kesişmiyorsa null.
PdfBox? clampLayerBox(PdfBox b, double pageW, double pageH) {
  final l = b.left < 0 ? 0.0 : b.left, t = b.top < 0 ? 0.0 : b.top;
  final r = b.right > pageW ? pageW : b.right, bt = b.bottom > pageH ? pageH : b.bottom;
  if (r - l < 1 || bt - t < 1) return null;
  return PdfBox(l, t, r, bt);
}

/// Z sıralı görünür katmanlarda [index]'teki katmanın görüntüsünü üretmek için
/// uygulanacak zincir: ondan ALTTAKİ tüm katmanlar (filigran VE örtü) ve kendisi.
/// Okuyucu üst katmanı (z sırasıyla çizdiği örtüleri) kendisi çizer; çözüm ekranı
/// ve önizleme `applyLayersToPixels` ile tüm listeyi aynı sırayla uygular: üçü
/// aynı sonucu verir.
List<PdfPageLayer> layerChainUpTo(List<PdfPageLayer> ordered, int index) => ordered.sublist(0, index + 1);
