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
  });

  final InkTool tool;
  final int color;
  final double width;
  final PenKind? kind;

  InkBrush copyWith({InkTool? tool, int? color, double? width, PenKind? kind}) => InkBrush(
    tool: tool ?? this.tool,
    color: color ?? this.color,
    width: width ?? this.width,
    kind: kind ?? this.kind,
  );

  @override
  bool operator ==(Object other) =>
      other is InkBrush &&
      other.tool == tool &&
      other.color == color &&
      other.width == width &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(tool, color, width, kind);

  @override
  String toString() => 'InkBrush($tool, #${color.toRadixString(16)}, w=$width${kind == null ? '' : ', $kind'})';
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
