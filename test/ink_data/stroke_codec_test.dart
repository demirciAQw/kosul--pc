import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';

void _close(List<StrokePoint> a, List<StrokePoint> b, {int scale = StrokeCodec.defaultScale}) {
  expect(b.length, a.length);
  for (var i = 0; i < a.length; i++) {
    expect((b[i].x - a[i].x).abs(), lessThanOrEqualTo(StrokeCodec.positionError(scale) + 1e-9));
    expect((b[i].y - a[i].y).abs(), lessThanOrEqualTo(StrokeCodec.positionError(scale) + 1e-9));
    expect((b[i].pressure - a[i].pressure.clamp(0.0, 1.0)).abs(), lessThanOrEqualTo(StrokeCodec.pressureError + 1e-9));
    expect((b[i].tilt - a[i].tilt).abs(), lessThanOrEqualTo(StrokeCodec.tiltError + 1e-9));
    expect(b[i].t, a[i].t);
  }
}

void main() {
  test('boş ve tek nokta', () {
    expect(StrokeCodec.decode(StrokeCodec.encode(const [])), isEmpty);
    const one = [StrokePoint(12.34, -5.67, pressure: 0.5, tilt: 0.3, t: 17)];
    _close(one, StrokeCodec.decode(StrokeCodec.encode(one)));
  });

  test('ikinci kodlama aynı baytları verir (niceleme sabit nokta)', () {
    final r = math.Random(1);
    final pts = [for (var i = 0; i < 50; i++) StrokePoint(r.nextDouble() * 500, r.nextDouble() * 800, pressure: r.nextDouble(), tilt: r.nextDouble(), t: i * 8)];
    final once = StrokeCodec.encode(pts);
    final dec = StrokeCodec.decode(once);
    expect(StrokeCodec.encode(dec), once);
  });

  test('rastgele round-trip: hata sınırları içinde', () {
    final r = math.Random(42);
    for (var k = 0; k < 40; k++) {
      final scale = [1, 10, 20, 100, 1000][r.nextInt(5)];
      var t = 0;
      final pts = [
        for (var i = 0; i < r.nextInt(300); i++)
          StrokePoint((r.nextDouble() - 0.5) * 20000, (r.nextDouble() - 0.5) * 20000,
              pressure: r.nextDouble(), tilt: (r.nextDouble() - 0.5) * math.pi, t: t += r.nextInt(30)),
      ];
      _close(pts, StrokeCodec.decode(StrokeCodec.encode(pts, scale: scale)), scale: scale);
    }
  });

  test('uç değerler: negatif, çok büyük, baskı dışı, geriye giden zaman', () {
    const pts = [
      StrokePoint(-1e7, 1e7, pressure: -0.5, tilt: -1.5, t: 5),
      StrokePoint(1e7, -1e7, pressure: 2, tilt: 1.5, t: 3),
      StrokePoint(0, 0, t: 1 << 40),
      StrokePoint(-0.0, 0.049, pressure: 1, t: 0),
    ];
    final out = StrokeCodec.decode(StrokeCodec.encode(pts));
    _close(pts, out);
    expect(out[0].pressure, 0);
    expect(out[1].pressure, 1);
  });

  test('sonlu olmayan sayı reddedilir', () {
    expect(() => StrokeCodec.encode([const StrokePoint(double.nan, 0)]), throwsArgumentError);
    expect(() => StrokeCodec.encode([const StrokePoint(0, double.infinity)]), throwsArgumentError);
    expect(() => StrokeCodec.encode(const [], scale: 0), throwsArgumentError);
  });

  test('sınır dışı değer sessizce bozulmaz, ArgumentError verir', () {
    expect(() => StrokeCodec.encode([const StrokePoint(1e18, 0)]), throwsArgumentError);
    expect(() => StrokeCodec.encode([const StrokePoint(0, -1e8)]), throwsArgumentError);
    expect(() => StrokeCodec.encode([const StrokePoint(0, 0, tilt: 100)]), throwsArgumentError);
    expect(() => StrokeCodec.encode([const StrokePoint(0, 0, tilt: double.nan)]), throwsArgumentError);
    expect(() => StrokeCodec.encode([const StrokePoint(double.nan, 0)]), throwsArgumentError);
    expect(StrokeCodec.decode(StrokeCodec.encode([const StrokePoint(1e7, -1e7, tilt: 6.5)])), hasLength(1));
  });

  test('bozuk veri FormatException verir', () {
    final good = StrokeCodec.encode([const StrokePoint(1, 2, t: 3), const StrokePoint(4, 5, t: 6)]);
    expect(() => StrokeCodec.decode(Uint8List(0)), throwsFormatException);
    expect(() => StrokeCodec.decode(Uint8List.fromList([9, 1, 0])), throwsFormatException);
    expect(() => StrokeCodec.decode(Uint8List.sublistView(good, 0, good.length - 1)), throwsFormatException);
    expect(() => StrokeCodec.decode(Uint8List.fromList([...good, 0])), throwsFormatException);
    // Şişirilmiş nokta sayısı.
    expect(() => StrokeCodec.decode(Uint8List.fromList([1, 20, 0xFF, 0xFF, 0xFF, 0x7F])), throwsFormatException);
    expect(() => StrokeCodec.decode(Uint8List.fromList([1, 20, ...List.filled(12, 0x80)])), throwsFormatException);
  });

  test('nokta sayısı başlıktan okunur', () {
    final b = StrokeCodec.encode([for (var i = 0; i < 300; i++) StrokePoint(i.toDouble(), 0, t: i)]);
    expect(StrokeCodec.pointCountOf(b), 300);
  });

  test('boyut: gerçekçi 1000 nokta ortalama 6 bayttan az', () {
    // Elle yazıya benzer: ~1-2 birim adım, yumuşak baskı/eğim, 8 ms aralık.
    final r = math.Random(7);
    var x = 100.0, y = 200.0, a = 0.0, p = 0.4;
    final pts = <StrokePoint>[];
    for (var i = 0; i < 1000; i++) {
      a += (r.nextDouble() - 0.5) * 0.3;
      x += math.cos(a) * 1.5;
      y += math.sin(a) * 1.5;
      p = (p + (r.nextDouble() - 0.5) * 0.02).clamp(0.05, 1.0);
      pts.add(StrokePoint(x, y, pressure: p, tilt: 0.6 + math.sin(i / 50) * 0.1, t: i * 8 + r.nextInt(3)));
    }
    final bytes = StrokeCodec.encode(pts);
    expect(bytes.length / pts.length, lessThan(6));
    _close(pts, StrokeCodec.decode(bytes));
  });
}
