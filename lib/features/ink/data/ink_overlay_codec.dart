/// Ink katmanı (Android yerel, FlutterView'in üstünde tam pencere saydam katman) ile Dart
/// arasındaki MethodChannel sözleşmesi (saf Dart). Kanal: `kocum/ink_overlay`.
///
/// Dart -> yerel: `ping` (katman var mı: bool), `setMode {mode: off|pen|highlighter}`,
/// `setBrush {family: pressurePen|marker|highlighter, argb, sizePx, epsilon}`,
/// `setRegions {rects: [[l,t,r,b], ...]}` (sayfaların ekrandaki dikdörtgenleri) ve
/// `setMask {rects}` (araç çubuğu gibi Flutter bölgeleri), hepsi FİZİKSEL piksel, pencere
/// koordinatı; `releaseStrokes {ids}`, `cancelCurrent`.
/// Yerel -> Dart: `strokeStart {id}`, `strokeFinished {id, family, argb, sizePx, points}`
/// (points: Float32List, nokta başına 6 sayı: x, y, tMs, pressure, tilt, orientation; x/y fiziksel
/// piksel pencere koordinatı, tMs çizgi başından beri ms, tilt/orientation radyan),
/// `strokeCanceled {id}`.
///
/// SAPMA (bilinçli): `strokeFinished` Ink'in toplu geri çağrısını (`onStrokesFinished`, gecikmeli)
/// beklemeden kalem kalkınca gider; `releaseStrokes` yerelde geri çağrı gelene dek bekletilir.
library;

import 'dart:ui' show Rect;

const inkOverlayChannelName = 'kocum/ink_overlay';

const inkOverlayPing = 'ping';
const inkOverlaySetMode = 'setMode';
const inkOverlaySetBrush = 'setBrush';
const inkOverlaySetRegions = 'setRegions';
const inkOverlaySetMask = 'setMask';
const inkOverlayReleaseStrokes = 'releaseStrokes';
const inkOverlayCancelCurrent = 'cancelCurrent';
const inkOverlayStrokeStart = 'strokeStart';
const inkOverlayStrokeFinished = 'strokeFinished';
const inkOverlayStrokeCanceled = 'strokeCanceled';

enum InkOverlayMode { off, pen, highlighter }

enum InkOverlayFamily { pressurePen, marker, highlighter }

/// Yerelden gelen tek nokta (fiziksel piksel, pencere koordinatı).
class OverlayPoint {
  const OverlayPoint({
    required this.x,
    required this.y,
    required this.tMs,
    required this.pressure,
    required this.tilt,
    required this.orientation,
  });
  final double x;
  final double y;
  final double tMs;
  final double pressure;
  final double tilt;
  final double orientation;

  @override
  bool operator ==(Object other) =>
      other is OverlayPoint &&
      other.x == x &&
      other.y == y &&
      other.tMs == tMs &&
      other.pressure == pressure &&
      other.tilt == tilt &&
      other.orientation == orientation;

  @override
  int get hashCode => Object.hash(x, y, tMs, pressure, tilt, orientation);

  @override
  String toString() => 'OverlayPoint($x, $y, t=$tMs, p=$pressure)';
}

/// Nokta başına sayı adedi (`strokeFinished.points`).
const inkOverlayPointStride = 6;

sealed class InkOverlayEvent {
  const InkOverlayEvent(this.id);
  final int id;
}

class OverlayStrokeStart extends InkOverlayEvent {
  const OverlayStrokeStart(super.id);
}

class OverlayStrokeFinished extends InkOverlayEvent {
  const OverlayStrokeFinished(
    super.id, {
    required this.family,
    required this.argb,
    required this.sizePx,
    required this.points,
  });
  final InkOverlayFamily family;
  final int argb;
  final double sizePx;
  final List<OverlayPoint> points;
}

class OverlayStrokeCanceled extends InkOverlayEvent {
  const OverlayStrokeCanceled(super.id);
}

// --- Dart -> yerel ---

Map<String, Object> encodeSetMode(InkOverlayMode mode) => {'mode': mode.name};

Map<String, Object> encodeSetBrush({
  required InkOverlayFamily family,
  required int argb,
  required double sizePx,
  double epsilon = 0.1,
}) => {
  'family': family.name,
  'argb': argb,
  'sizePx': sizePx.isFinite && sizePx > 0 ? sizePx : 1.0,
  'epsilon': epsilon.isFinite && epsilon > 0 ? epsilon : 0.1,
};

/// `setRegions` ve `setMask` bağımsız değişkeni. Sonlu olmayan ya da boş dikdörtgenler atılır.
Map<String, Object> encodeRects(Iterable<Rect> rects) => {
  'rects': [
    for (final r in rects)
      if (r.left.isFinite && r.top.isFinite && r.right.isFinite && r.bottom.isFinite && !r.isEmpty)
        [r.left, r.top, r.right, r.bottom],
  ],
};

Map<String, Object> encodeRelease(Iterable<int> ids) => {'ids': ids.toList()};

// --- yerel -> Dart ---

/// Yerelden gelen çağrıyı olaya çevirir. Bilinmeyen yöntem için null; bozuk bağımsız
/// değişken için [FormatException].
InkOverlayEvent? decodeOverlayCall(String method, Object? args) {
  if (method != inkOverlayStrokeStart && method != inkOverlayStrokeFinished && method != inkOverlayStrokeCanceled) {
    return null;
  }
  if (args is! Map) throw FormatException('$method: bağımsız değişken eşleme değil', args);
  final id = args['id'];
  if (id is! num) throw FormatException('$method: id yok', args);
  switch (method) {
    case inkOverlayStrokeStart:
      return OverlayStrokeStart(id.toInt());
    case inkOverlayStrokeCanceled:
      return OverlayStrokeCanceled(id.toInt());
  }
  final family = InkOverlayFamily.values.where((f) => f.name == args['family']).firstOrNull;
  final argb = args['argb'];
  final size = args['sizePx'];
  final raw = args['points'];
  if (family == null || argb is! num || size is! num || raw is! List<num>) {
    throw FormatException('$method: alan eksik ya da türü yanlış', args);
  }
  if (raw.length % inkOverlayPointStride != 0) {
    throw FormatException('$method: nokta sayısı $inkOverlayPointStride katı değil', args);
  }
  return OverlayStrokeFinished(
    id.toInt(),
    family: family,
    argb: argb.toInt(),
    sizePx: size.toDouble(),
    points: [
      for (var i = 0; i < raw.length; i += inkOverlayPointStride)
        OverlayPoint(
          x: raw[i].toDouble(),
          y: raw[i + 1].toDouble(),
          tMs: raw[i + 2].toDouble(),
          pressure: raw[i + 3].toDouble(),
          tilt: raw[i + 4].toDouble(),
          orientation: raw[i + 5].toDouble(),
        ),
    ],
  );
}
