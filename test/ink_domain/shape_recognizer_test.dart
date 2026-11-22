import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/shape_recognizer.dart';

List<InkPoint> _noisy(
  List<List<double>> poly, {
  required double size,
  int per = 30,
  bool closed = true,
  int seed = 1,
  double noise = 0.03,
  int startShift = 0,
}) {
  final r = math.Random(seed);
  final out = <InkPoint>[];
  final n = closed ? poly.length : poly.length - 1;
  for (var i = 0; i < n; i++) {
    final a = poly[(i + startShift) % poly.length];
    final b = poly[(i + 1 + startShift) % poly.length];
    for (var k = 0; k < per; k++) {
      final t = k / per;
      out.add(InkPoint(
        x: a[0] + (b[0] - a[0]) * t + (r.nextDouble() * 2 - 1) * noise * size,
        y: a[1] + (b[1] - a[1]) * t + (r.nextDouble() * 2 - 1) * noise * size,
      ));
    }
  }
  if (closed) out.add(out.first);
  return out;
}

List<InkPoint> _ellipse(double rx, double ry, {int seed = 1, double rot = 0}) {
  final r = math.Random(seed);
  final out = <InkPoint>[];
  for (var i = 0; i <= 120; i++) {
    final t = 2 * math.pi * i / 120;
    final u = rx * math.cos(t), v = ry * math.sin(t);
    final s = math.max(rx, ry);
    out.add(InkPoint(
      x: 300 + u * math.cos(rot) - v * math.sin(rot) + (r.nextDouble() * 2 - 1) * 0.03 * s,
      y: 300 + u * math.sin(rot) + v * math.cos(rot) + (r.nextDouble() * 2 - 1) * 0.03 * s,
    ));
  }
  return out;
}

void main() {
  test('düz çizgi', () {
    for (var seed = 0; seed < 10; seed++) {
      final res = recognizeShape(_noisy([[0, 0], [200, 60]], size: 200, closed: false, seed: seed, per: 60));
      expect(res?.type, ShapeType.line, reason: 'seed $seed');
      expect(res!.points.length, 2);
    }
  });

  test('daire', () {
    for (var seed = 0; seed < 10; seed++) {
      final res = recognizeShape(_ellipse(100, 100, seed: seed));
      expect(res?.type, ShapeType.circle, reason: 'seed $seed');
      expect(res!.keyPoints[1].x, closeTo(100, 8));
    }
  });

  test('elips (dönük de)', () {
    for (var seed = 0; seed < 10; seed++) {
      expect(recognizeShape(_ellipse(150, 70, seed: seed))?.type, ShapeType.ellipse);
      expect(recognizeShape(_ellipse(150, 70, seed: seed, rot: 0.6))?.type, ShapeType.ellipse);
    }
  });

  test('kare ve dikdörtgen, başlangıç köşede olmasa da', () {
    for (var seed = 0; seed < 10; seed++) {
      final sq = [[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0]];
      for (final shift in [0, 2]) {
        final r = recognizeShape(_noisy(sq, size: 100, seed: seed, startShift: shift));
        expect(r?.type, ShapeType.rectangle, reason: 'kare seed $seed shift $shift');
        expect(r!.keyPoints.length, 4);
        expect(r.points.first.x, r.points.last.x);
      }
      final rect = [[0.0, 0.0], [200.0, 0.0], [200.0, 90.0], [0.0, 90.0]];
      expect(recognizeShape(_noisy(rect, size: 200, seed: seed))?.type, ShapeType.rectangle,
          reason: 'dikdörtgen seed $seed');
    }
  });

  test('eğik dörtgen ve üçgen', () {
    for (var seed = 0; seed < 10; seed++) {
      final q = [[0.0, 0.0], [200.0, 0.0], [150.0, 100.0], [40.0, 100.0]];
      expect(recognizeShape(_noisy(q, size: 200, seed: seed))?.type, ShapeType.quadrilateral,
          reason: 'dörtgen seed $seed');
      final t = [[0.0, 100.0], [100.0, 100.0], [50.0, 10.0]];
      for (final shift in [0, 1]) {
        final r = recognizeShape(_noisy(t, size: 100, seed: seed, startShift: shift));
        expect(r?.type, ShapeType.triangle, reason: 'üçgen seed $seed');
        expect(r!.keyPoints.length, 3);
      }
    }
  });

  test('şekil olmayanlar null döner', () {
    // dalgalı çizgi
    final wave = [
      for (var i = 0; i <= 100; i++)
        InkPoint(x: i * 3.0, y: 40 * math.sin(i / 8)),
    ];
    expect(recognizeShape(wave), isNull);
    // yazı gibi: kıvrımlı kapalı olmayan
    final scribble = [
      for (var i = 0; i <= 150; i++)
        InkPoint(x: i * 2.0 + 20 * math.sin(i / 3), y: 30 * math.cos(i / 5) + 20 * math.sin(i / 2)),
    ];
    expect(recognizeShape(scribble), isNull);
    // sekiz (kapalı ama elips değil)
    final eight = [
      for (var i = 0; i <= 120; i++)
        InkPoint(
          x: 100 * math.sin(2 * math.pi * i / 120),
          y: 100 * math.sin(4 * math.pi * i / 120) / 2,
        ),
    ];
    expect(recognizeShape(eight), isNull);
    // yıldız / beş köşe
    final star = [
      for (var i = 0; i <= 5; i++)
        [100 * math.cos(i * 4 * math.pi / 5), 100 * math.sin(i * 4 * math.pi / 5)],
    ];
    expect(recognizeShape(_noisy(star, size: 100, closed: false)), isNull);
    // spiral
    final spiral = [
      for (var i = 0; i <= 200; i++)
        InkPoint(x: (10 + i * 0.5) * math.cos(i / 10), y: (10 + i * 0.5) * math.sin(i / 10)),
    ];
    expect(recognizeShape(spiral), isNull);
  });

  test('kenar durumlar', () {
    expect(recognizeShape(const []), isNull);
    expect(recognizeShape(const [InkPoint(x: 1, y: 1)]), isNull);
    expect(recognizeShape([for (var i = 0; i < 10; i++) const InkPoint(x: 5, y: 5)]), isNull);
  });
}
