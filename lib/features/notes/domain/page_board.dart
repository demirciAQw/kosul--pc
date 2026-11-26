import 'dart:convert';

/// Pano (sayfa kartlarının serbest yerleşimi) ve sayfa öğelerinin veri modelleri (v23).

/// Pano biriminde dikdörtgen (sol-üst köşe + boyut). Flutter'a bağlı değil.
class BoardRect {
  const BoardRect(this.x, this.y, this.w, this.h);
  final double x;
  final double y;
  final double w;
  final double h;

  double get right => x + w;
  double get bottom => y + h;
  double get cx => x + w / 2;
  double get cy => y + h / 2;

  bool overlaps(BoardRect o) => x < o.right && o.x < right && y < o.bottom && o.y < bottom;

  @override
  bool operator ==(Object other) => other is BoardRect && other.x == x && other.y == y && other.w == w && other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'BoardRect($x, $y, $w x $h)';
}

class BoardPoint {
  const BoardPoint(this.x, this.y);
  final double x;
  final double y;

  @override
  bool operator ==(Object other) => other is BoardPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'BoardPoint($x, $y)';
}

/// Panodaki bir sayfa kartı. Konum/boyut null ise henüz yerleşmemiş / varsayılan boyut.
class BoardCard {
  const BoardCard({
    required this.pageId,
    required this.notebookId,
    required this.pageNo,
    this.title,
    this.konuId,
    this.parentPageId,
    this.x,
    this.y,
    this.w,
    this.h,
  });

  final String pageId;
  final String notebookId;
  final int pageNo;
  final String? title;
  final String? konuId;
  final String? parentPageId;
  final double? x;
  final double? y;
  final double? w;
  final double? h;

  bool get placed => x != null && y != null;

  /// Kart dikdörtgeni; yerleşmemişse null. Boyut yoksa [defaultW] x [defaultH].
  BoardRect? rect({double defaultW = boardCardW, double defaultH = boardCardH}) =>
      placed ? BoardRect(x!, y!, w ?? defaultW, h ?? defaultH) : null;
}

/// Varsayılan kart boyutu (pano birimi).
const boardCardW = 320.0;
const boardCardH = 420.0;

enum PageLinkKind {
  link('link'),
  child('child'),
  konu('konu');

  const PageLinkKind(this.key);
  final String key;

  /// Bilinmeyen anahtar (yeni sürümden gelen) elle bağlantı sayılır.
  static PageLinkKind fromKey(String? key) => PageLinkKind.values.where((k) => k.key == key).firstOrNull ?? PageLinkKind.link;
}

class PageLinkRecord {
  const PageLinkRecord({
    required this.id,
    required this.notebookId,
    required this.fromPageId,
    required this.toPageId,
    required this.fromX,
    required this.fromY,
    required this.label,
    required this.kind,
    required this.color,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String notebookId;
  final String fromPageId;
  final String toPageId;
  final double? fromX;
  final double? fromY;
  final String label;
  final PageLinkKind kind;
  final int color;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;
}

enum PageItemKind {
  text('text'),
  image('image');

  const PageItemKind(this.key);
  final String key;

  static PageItemKind? fromKey(String? key) => PageItemKind.values.where((k) => k.key == key).firstOrNull;
}

/// Metin kutusunun yükü (`payload`).
class TextItemPayload {
  const TextItemPayload({
    this.text = '',
    this.fontSize = 28,
    this.color = 0xFF000000,
    this.bold = false,
    this.italic = false,
    this.align = 'left',
  });

  final String text;
  final double fontSize;
  final int color;
  final bool bold;
  final bool italic;

  /// left | center | right
  final String align;

  TextItemPayload copyWith({String? text, double? fontSize, int? color, bool? bold, bool? italic, String? align}) =>
      TextItemPayload(
        text: text ?? this.text,
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        align: align ?? this.align,
      );

  String toJson() => jsonEncode({
        'text': text,
        'fontSize': fontSize,
        'color': color,
        'bold': bold,
        'italic': italic,
        'align': align,
      });

  /// Bozuk/eksik yük hata fırlatmaz: varsayılanlarla okunur (yeni sürümden gelen alanlar yok sayılır).
  factory TextItemPayload.fromJson(String? raw) {
    final m = _decodeMap(raw);
    const d = TextItemPayload();
    return TextItemPayload(
      text: m['text'] is String ? m['text'] as String : d.text,
      fontSize: m['fontSize'] is num ? (m['fontSize'] as num).toDouble() : d.fontSize,
      color: m['color'] is int ? m['color'] as int : d.color,
      bold: m['bold'] == true,
      italic: m['italic'] == true,
      align: const {'left', 'center', 'right'}.contains(m['align']) ? m['align'] as String : d.align,
    );
  }
}

/// Görsel öğenin yükü (`payload`); dosya yolu `mediaPath` sütunundadır.
class ImageItemPayload {
  const ImageItemPayload({this.pxW = 0, this.pxH = 0, this.alpha = 1.0});

  final int pxW;
  final int pxH;

  /// 0..1 saydamlık (1 = opak).
  final double alpha;

  ImageItemPayload copyWith({int? pxW, int? pxH, double? alpha}) =>
      ImageItemPayload(pxW: pxW ?? this.pxW, pxH: pxH ?? this.pxH, alpha: alpha ?? this.alpha);

  String toJson() => jsonEncode({'pxW': pxW, 'pxH': pxH, 'alpha': alpha});

  factory ImageItemPayload.fromJson(String? raw) {
    final m = _decodeMap(raw);
    final a = m['alpha'] is num ? (m['alpha'] as num).toDouble() : 1.0;
    return ImageItemPayload(
      pxW: m['pxW'] is num ? (m['pxW'] as num).toInt() : 0,
      pxH: m['pxH'] is num ? (m['pxH'] as num).toInt() : 0,
      alpha: a.isNaN ? 1.0 : a.clamp(0.0, 1.0),
    );
  }
}

Map<String, Object?> _decodeMap(String? raw) {
  if (raw == null || raw.isEmpty) return const {};
  try {
    final v = jsonDecode(raw);
    return v is Map<String, Object?> ? v : const {};
  } catch (_) {
    return const {};
  }
}

/// Sayfadaki metin kutusu ya da görsel.
class PageItemRecord {
  const PageItemRecord({
    required this.id,
    required this.pageId,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.rotation,
    required this.z,
    required this.payloadJson,
    required this.mediaPath,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String pageId;

  /// Bilinmeyen tür (yeni sürümden gelen) null: arayüz görmezden gelir.
  final PageItemKind? kind;
  final double x;
  final double y;
  final double w;
  final double h;

  /// Radyan.
  final double rotation;
  final int z;
  final String payloadJson;

  /// Yalnız görselde: `notes/yyyy/mm/ad.uzantı`.
  final String? mediaPath;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  BoardRect get rect => BoardRect(x, y, w, h);
  TextItemPayload get text => TextItemPayload.fromJson(payloadJson);
  ImageItemPayload get image => ImageItemPayload.fromJson(payloadJson);
}
