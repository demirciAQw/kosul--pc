import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/eraser.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_object.dart';

InkPoint p(double x, double y, [double pr = 0.5, double t = 0]) =>
    InkPoint(x: x, y: y, pressure: pr, tMs: t);

InkObject line(String id, {double w = 2, int n = 11}) => InkObject(
  id: id,
  brush: InkBrush(color: 0xFF112233, width: w),
  points: [for (var i = 0; i < n; i++) p(i * 10.0, 0, 0.1 * i, i * 5.0)],
);

void main() {
  group('çizgi silgisi', () {
    test('değen döner, değmeyen dönmez', () {
      final a = line('a');
      final b = InkObject(id: 'b', points: [p(0, 100), p(100, 100)]);
      final hit = strokesTouchedByEraser([a, b], [p(50, 4)], 5);
      expect(hit.map((e) => e.id), ['a']);
    });
    test('kalınlık hesaba katılır', () {
      final a = line('a', w: 10);
      expect(strokesTouchedByEraser([a], [p(50, 9)], 5), isNotEmpty);
      expect(strokesTouchedByEraser([a], [p(50, 11)], 5), isEmpty);
    });
    test('tek nokta çizgi', () {
      final a = InkObject(id: 'a', points: [p(5, 5)], brush: const InkBrush(width: 2));
      expect(strokesTouchedByEraser([a], [p(8, 5)], 3), isNotEmpty);
      expect(strokesTouchedByEraser([a], [p(30, 5)], 3), isEmpty);
    });
    test('silgi yolu çizgiyi iki nokta arasında keser', () {
      final a = InkObject(id: 'a', points: [p(0, 0), p(100, 0)]);
      expect(strokesTouchedByEraser([a], [p(50, -20), p(50, 20)], 1), isNotEmpty);
    });
    test('boş silgi yolu', () {
      expect(strokesTouchedByEraser([line('a')], const [], 5), isEmpty);
    });
  });

  group('alan silgisi', () {
    test('ortadan böler, özellikler korunur', () {
      final a = line('a', w: 3);
      final r = eraseArea(a, [p(50, 0)], 8);
      expect(r.changed, isTrue);
      expect(r.pieces.length, 2);
      expect(r.pieces[0].id, 'a#0');
      expect(r.pieces[1].id, 'a#1');
      for (final s in r.pieces) {
        expect(s.brush, a.brush);
        expect(s.points.length, greaterThanOrEqualTo(2));
      }
      expect(r.pieces[0].points.last.x, lessThan(50 - 8));
      expect(r.pieces[1].points.first.x, greaterThan(50 + 8));
      // baskı ve zaman özgün noktalardan gelir
      expect(r.pieces[0].points.first.pressure, 0);
      expect(r.pieces[1].points.last.tMs, 50);
      expect(r.pieces[1].points.last.pressure, closeTo(1.0, 1e-9));
    });
    test('hiç değmiyorsa aynı nesne', () {
      final a = line('a');
      final r = eraseArea(a, [p(50, 50)], 5);
      expect(r.changed, isFalse);
      expect(r.pieces.single, same(a));
    });
    test('silgi tam üstünde ve büyük: hiçbir şey kalmaz', () {
      final a = line('a');
      final r = eraseArea(a, [p(50, 0)], 200);
      expect(r.changed, isTrue);
      expect(r.pieces, isEmpty);
    });
    test('başı silinince tek parça', () {
      final r = eraseArea(line('a'), [p(0, 0)], 15);
      expect(r.pieces.length, 1);
      expect(r.pieces.single.points.first.x, greaterThan(15));
    });
    test('tek nokta çizgi silinir', () {
      final a = InkObject(id: 'a', points: [p(5, 5)]);
      expect(eraseArea(a, [p(5, 5)], 3).pieces, isEmpty);
      expect(eraseArea(a, [p(50, 5)], 3).pieces.single, same(a));
    });
    test('seyrek çizgide silgi arada kalsa da bölünür', () {
      final a = InkObject(id: 'a', points: [p(0, 0), p(200, 0)]);
      final r = eraseArea(a, [p(100, 0)], 5);
      expect(r.pieces.length, 2);
    });
    test('silgi yolu çizgiyi dik keserse böler', () {
      final r = eraseArea(line('a'), [p(50, -30), p(50, 30)], 4);
      expect(r.pieces.length, 2);
    });
  });
}
