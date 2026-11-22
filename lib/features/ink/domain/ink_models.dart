/// Kalem çizimi için ortak, platformdan bağımsız model (saf Dart).
///
/// Çizim yüzeyi (`InkSurface`) iki uygulamayla gelir: A (Android yerel) ve
/// B (saf Flutter). İleride iOS/HarmonyOS yalnızca yeni bir uygulama yazar;
/// bu dosyadaki sözleşme değişmez.
library;

import 'pen_profiles.dart' show PenKind;

/// Çizgi üzerindeki tek nokta.
class InkPoint {
  const InkPoint({
    required this.x,
    required this.y,
    this.pressure = 0.5,
    this.tilt = 0,
    this.tMs = 0,
  });

  /// Yüzey koordinatı (mantıksal piksel; görünüm dönüşümünden bağımsız).
  final double x;
  final double y;

  /// 0..1 arası baskı.
  final double pressure;

  /// Kalemin eğimi, radyan (0 = dik).
  final double tilt;

  /// Zaman damgası (milisaniye).
  final double tMs;

  @override
  bool operator ==(Object other) =>
      other is InkPoint &&
      other.x == x &&
      other.y == y &&
      other.pressure == pressure &&
      other.tilt == tilt &&
      other.tMs == tMs;

  @override
  int get hashCode => Object.hash(x, y, pressure, tilt, tMs);

  @override
  String toString() => 'InkPoint($x, $y, p=$pressure, tilt=$tilt, t=$tMs)';
}

enum InkTool { pen, highlighter, eraser }

/// Fırça: araç, ARGB renk (0xAARRGGBB) ve kalınlık (mantıksal piksel).
///
/// [kind] yalnız not uygulamasında verilir (tükenmez/dolma/kurşun/fosforlu);
/// verilirse çizgi biçimi `pen_profiles` profilinden gelir. Null: eski davranış.
class InkBrush {
  const InkBrush({
    this.tool = InkTool.pen,
    this.color = 0xFF1B1B1F,
    this.width = 3,
    this.kind,
    this.hardness,
  });

  final InkTool tool;
  final int color;
  final double width;
  final PenKind? kind;

  /// Baskı eğrisi sertliği (0..1) ÇİZİMDE uygulanır; çizgi ham baskıyı taşır.
  /// null: baskı olduğu gibi (sabit baskılı çizgi ve sertlik yazılmadan önceki kayıtlar).
  final double? hardness;

  static const _keep = Object();

  /// [kind] ve [hardness] null'a çevrilebilir: `kind: null` verilirse silinir,
  /// hiç verilmezse korunur.
  InkBrush copyWith({InkTool? tool, int? color, double? width, Object? kind = _keep, Object? hardness = _keep}) =>
      InkBrush(
        tool: tool ?? this.tool,
        color: color ?? this.color,
        width: width ?? this.width,
        kind: identical(kind, _keep) ? this.kind : kind as PenKind?,
        hardness: identical(hardness, _keep) ? this.hardness : (hardness as num?)?.toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is InkBrush &&
      other.tool == tool &&
      other.color == color &&
      other.width == width &&
      other.kind == kind &&
      other.hardness == hardness;

  @override
  int get hashCode => Object.hash(tool, color, width, kind, hardness);

  @override
  String toString() =>
      'InkBrush($tool, #${color.toRadixString(16)}, w=$width${kind == null ? '' : ', $kind'}${hardness == null ? '' : ', h=$hardness'})';
}

/// `tool` sütunu değeri: kalem türü adı, sertlik varsa `ad:0.80` (ham baskı + sertlik çizimde).
/// Sertliksiz eski kayıtlar yalnız adı taşır (baskıları yazılırken biçimlenmiştir).
String toolColumnOf(InkBrush b) {
  final k = b.kind;
  if (k == null) return b.tool.name;
  final h = b.hardness;
  return h == null ? k.name : '${k.name}:${h.toStringAsFixed(2)}';
}

/// [toolColumnOf]'un tersi: ad ve (varsa) sertlik.
({String name, double? hardness}) parseToolColumn(String v) {
  final i = v.indexOf(':');
  if (i < 0) return (name: v, hardness: null);
  final h = double.tryParse(v.substring(i + 1));
  return (name: v.substring(0, i), hardness: h?.clamp(0.0, 1.0));
}

/// Yüzeyden çıkan olaylar.
sealed class InkEvent {
  const InkEvent(this.strokeId);

  /// Çizgi numarası (başlangıçtan bitişe aynı).
  final int strokeId;

  /// İptal olayında nokta yoktur.
  InkPoint? get point;
}

class InkStrokeStart extends InkEvent {
  const InkStrokeStart(super.strokeId, this.point);
  @override
  final InkPoint point;
}

class InkStrokePoint extends InkEvent {
  const InkStrokePoint(super.strokeId, this.point);
  @override
  final InkPoint point;
}

class InkStrokeEnd extends InkEvent {
  const InkStrokeEnd(super.strokeId, this.point);
  @override
  final InkPoint point;
}

/// Çizgi iptal edildi (ACTION_CANCEL, avuç): yarım çizgi atılır.
class InkStrokeCancel extends InkEvent {
  const InkStrokeCancel(super.strokeId);
  @override
  InkPoint? get point => null;
}

/// Platforma özgü her şeyin arkasında durduğu çizim yüzeyi denetleyicisi.
/// Widget'ı uygulama (A/B) kendi katmanında üretir; arayüz Flutter'a bağlı
/// değildir.
abstract interface class InkSurface {
  /// Çizgi başladı / nokta eklendi / çizgi bitti olayları.
  Stream<InkEvent> get events;

  InkBrush get brush;

  /// true: yalnızca kalem çizer (parmak çizmez).
  bool get stylusOnly;

  void setBrush(InkBrush brush);

  /// Tüm çizgileri siler.
  void clear();

  void setInputMode({required bool stylusOnly});

  void dispose();
}
