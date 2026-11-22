/// Çizgi noktalarının sıkıştırılmış ikili kodlaması (saf Dart).
///
/// Biçim: `[sürüm][ölçek varint][nokta sayısı varint]` + her nokta için
/// `dx, dy, dBaskı, dEğim, dZaman` (bir öncekine göre fark, zigzag + varint).
/// Koordinatlar `ölçek` ile çarpılıp yuvarlanır (varsayılan 20: 0,05 birim
/// çözünürlük), baskı 0..1023, eğim 1/512 radyan basamağına indirilir.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Çizgi noktası. [x], [y]: sayfa/not koordinatı; [pressure]: 0..1;
/// [tilt]: radyan; [t]: çizginin başından beri geçen ms.
class StrokePoint {
  const StrokePoint(this.x, this.y, {this.pressure = 0, this.tilt = 0, this.t = 0});

  final double x;
  final double y;
  final double pressure;
  final double tilt;
  final int t;

  @override
  bool operator ==(Object other) =>
      other is StrokePoint &&
      other.x == x &&
      other.y == y &&
      other.pressure == pressure &&
      other.tilt == tilt &&
      other.t == t;

  @override
  int get hashCode => Object.hash(x, y, pressure, tilt, t);

  @override
  String toString() => 'StrokePoint($x, $y, p=$pressure, tilt=$tilt, t=$t)';
}

class StrokeCodec {
  const StrokeCodec._();

  static const int version = 1;
  static const int defaultScale = 20;
  static const int pressureLevels = 1023;
  static const int tiltSteps = 512; // radyan başına

  /// En büyük nicelleme hataları (ölçeğe göre konum).
  static double positionError(int scale) => 0.5 / scale;
  static const double pressureError = 0.5 / pressureLevels;
  static const double tiltError = 0.5 / tiltSteps;

  static Uint8List encode(List<StrokePoint> points, {int scale = defaultScale}) {
    if (scale < 1 || scale > 1000000) throw ArgumentError.value(scale, 'scale');
    final w = _Writer()
      ..byte(version)
      ..varint(scale)
      ..varint(points.length);
    var px = 0, py = 0, pp = 0, pa = 0, pt = 0;
    for (final p in points) {
      if (!p.x.isFinite || !p.y.isFinite || !p.pressure.isFinite || !p.tilt.isFinite) {
        throw ArgumentError('Nokta sonlu sayı olmalı: $p');
      }
      final x = (p.x * scale).round();
      final y = (p.y * scale).round();
      final pr = (p.pressure.clamp(0.0, 1.0) * pressureLevels).round();
      final ti = (p.tilt * tiltSteps).round();
      w
        ..zigzag(x - px)
        ..zigzag(y - py)
        ..zigzag(pr - pp)
        ..zigzag(ti - pa)
        ..zigzag(p.t - pt);
      px = x;
      py = y;
      pp = pr;
      pa = ti;
      pt = p.t;
    }
    return w.takeBytes();
  }

  /// Bozuk ya da kesik veri için [FormatException] fırlatır.
  static List<StrokePoint> decode(Uint8List data) {
    final r = _Reader(data);
    final v = r.byte();
    if (v != version) throw FormatException('Bilinmeyen çizgi sürümü: $v');
    final scale = r.varint();
    if (scale < 1) throw const FormatException('Bozuk ölçek');
    final n = r.varint();
    // Her nokta en az 5 bayt: şişirilmiş sayı bellek tüketmesin.
    if (n < 0 || n > (data.length - r.pos) ~/ 5) throw const FormatException('Bozuk nokta sayısı');
    final out = <StrokePoint>[];
    var x = 0, y = 0, pr = 0, ti = 0, t = 0;
    for (var i = 0; i < n; i++) {
      x += r.zigzag();
      y += r.zigzag();
      pr += r.zigzag();
      ti += r.zigzag();
      t += r.zigzag();
      out.add(StrokePoint(x / scale, y / scale, pressure: pr / pressureLevels, tilt: ti / tiltSteps, t: t));
    }
    if (r.pos != data.length) throw const FormatException('Fazladan veri');
    return out;
  }

  /// Çizgi başlığındaki nokta sayısı (noktaları çözmeden).
  static int pointCountOf(Uint8List data) {
    final r = _Reader(data);
    if (r.byte() != version) throw const FormatException('Bilinmeyen çizgi sürümü');
    r.varint();
    return r.varint();
  }

  /// Yardımcı: noktaların süresi (ms).
  static int durationOf(List<StrokePoint> pts) =>
      pts.isEmpty ? 0 : pts.map((p) => p.t).reduce(math.max) - pts.map((p) => p.t).reduce(math.min);
}

class _Writer {
  final _b = BytesBuilder(copy: false);

  void byte(int v) => _b.addByte(v);

  void varint(int v) {
    var u = v; // negatif olmayan beklenir; zigzag zaten işaretsiz verir
    while (u < 0 || u >= 0x80) {
      _b.addByte((u & 0x7F) | 0x80);
      u = u >>> 7;
    }
    _b.addByte(u);
  }

  void zigzag(int n) => varint((n << 1) ^ (n >> 63));

  Uint8List takeBytes() => _b.takeBytes();
}

class _Reader {
  _Reader(this.d);
  final Uint8List d;
  int pos = 0;

  int byte() {
    if (pos >= d.length) throw const FormatException('Veri kesik');
    return d[pos++];
  }

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      final b = byte();
      result |= (b & 0x7F) << shift;
      if (b < 0x80) return result;
    }
    throw const FormatException('Bozuk sayı');
  }

  int zigzag() {
    final u = varint();
    return (u >>> 1) ^ -(u & 1);
  }
}
