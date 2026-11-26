import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_object.dart';
import 'package:kocum/features/ink/domain/lasso.dart';

InkPoint p(double x, double y) => InkPoint(x: x, y: y, pressure: 0.7, tMs: 3);

final square = [p(0, 0), p(100, 0), p(100, 100), p(0, 100)];

InkObject s(String id, List<InkPoint> pts, {double w = 4}) =>
    InkObject(id: id, points: pts, brush: InkBrush(width: w));

void main() {
  test('nokta çokgen içinde', () {
    expect(pointInPolygon(square, 50, 50), isTrue);
    expect(pointInPolygon(square, 150, 50), isFalse);
    expect(pointInPolygon([p(0, 0), p(1, 1)], 0, 0), isFalse);
    // içbükey (L)
    final l = [p(0, 0), p(100, 0), p(100, 40), p(40, 40), p(40, 100), p(0, 100)];
    expect(pointInPolygon(l, 70, 70), isFalse);
    expect(pointInPolygon(l, 20, 70), isTrue);
  });

  test('çizgi seçimi oran ile', () {
    final inside = s('i', [p(10, 10), p(90, 90)]);
    final outside = s('o', [p(200, 200), p(300, 300)]);
    final half = s('h', [p(50, 50), p(60, 60), p(150, 50), p(160, 50)]);
    final mostlyOut = s('m', [p(50, 50), p(150, 50), p(160, 50), p(170, 50)]);
    final r = selectByLasso([inside, outside, half, mostlyOut], square);
    expect(r.map((e) => e.id), ['i', 'h']);
    expect(selectByLasso([mostlyOut], square, ratio: 0.2), isNotEmpty);
    expect(selectByLasso([inside], [p(0, 0), p(1, 1)]), isEmpty);
  });

  test('sınır kutusu kalınlık dahil', () {
    expect(selectionBounds(const []), isNull);
    final b = selectionBounds([s('a', [p(10, 20), p(30, 50)], w: 4)])!;
    expect(b, const InkRect(8, 18, 32, 52));
    final b2 = selectionBounds([
      s('a', [p(0, 0)], w: 2),
      s('b', [p(10, 10)], w: 2),
    ])!;
    expect(b2, const InkRect(-1, -1, 11, 11));
  });

  test('taşı: baskı ve zaman korunur', () {
    final t = translateObject(s('a', [p(1, 2), p(3, 4)]), 10, -5);
    expect(t.points[0].x, 11);
    expect(t.points[0].y, -3);
    expect(t.points[0].pressure, 0.7);
    expect(t.points[0].tMs, 3);
    expect(t.brush.width, 4);
  });

  test('ölçekle: kalınlık koru ya da orantıla', () {
    final a = s('a', [p(10, 10), p(20, 20)]);
    final k = scaleObject(a, 2, 2, 0, 0);
    expect(k.points[1].x, 40);
    expect(k.brush.width, 4);
    final o = scaleObject(a, 2, 2, 0, 0, scaleWidth: true);
    expect(o.brush.width, closeTo(8, 1e-9));
    final neg = scaleObject(a, -1, 1, 15, 0);
    expect(neg.points[0].x, 20);
  });

  test('döndür', () {
    final r = rotateObject(s('a', [p(10, 0)]), math.pi / 2, 0, 0);
    expect(r.points.single.x, closeTo(0, 1e-9));
    expect(r.points.single.y, closeTo(10, 1e-9));
    final back = rotateObject(r, -math.pi / 2, 0, 0);
    expect(back.points.single.x, closeTo(10, 1e-9));
  });

  test('seçimi yeniden boyutlandır', () {
    final a = s('a', [p(0, 0), p(10, 10)], w: 2);
    final from = selectionBounds([a])!; // -1..11
    final to = InkRect(from.left + 100, from.top, from.left + 100 + from.width * 2, from.top + from.height * 2);
    final r = resizeSelection([a], from, to).single;
    expect(r.points[0].x, closeTo(99 + 2, 1e-9)); // (0 - -1)*2 + 99... 
    expect(r.points[1].x - r.points[0].x, closeTo(20, 1e-9));
    final k = resizeSelection([a], from, InkRect(0, 0, 24, 12), keepAspect: true).single;
    expect((k.points[1].x - k.points[0].x), closeTo(k.points[1].y - k.points[0].y, 1e-9));
    // sıfır genişlikli kutu patlamaz
    expect(resizeSelection([a], const InkRect(0, 0, 0, 0), const InkRect(5, 5, 5, 5)), hasLength(1));
  });

  test('hedef kutu sıfır genişlik/yükseklik: çökme ve sıfır kalınlık yok', () {
    final a = s('a', [p(0, 0), p(10, 10)], w: 2);
    final from = selectionBounds([a])!;
    final to = InkRect(5, 5, 5, 5);
    final r = resizeSelection([a], from, to, scaleWidth: true).single;
    expect(r.brush.width, greaterThan(0));
    expect(r.points[1].x, greaterThan(r.points[0].x)); // iki nokta ayrı kalır
    expect(r.points[1].y, greaterThan(r.points[0].y));
    final k = resizeSelection([a], from, to, keepAspect: true, scaleWidth: true).single;
    expect(k.brush.width, greaterThan(0));
    expect(k.points[1].x, isNot(k.points[0].x));
    // ters çevirme (negatif ölçek) işaretini korur
    final flip = resizeSelection([a], from, InkRect(from.left, from.top, from.left - 0.0, from.bottom)).single;
    expect(flip.points[1].x, greaterThan(flip.points[0].x));
  });
}
