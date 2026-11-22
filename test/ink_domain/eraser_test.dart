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
      final r = eraseArea(a, [p(50, 0)], 8, idFor: (b, i) => '$b#$i');
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

    test('varsayılan parça kimlikleri UUID: çağrılar arasında benzersiz', () {
      final a = line('a');
      final r1 = eraseArea(a, [p(50, 0)], 8);
      final r2 = eraseArea(a, [p(50, 0)], 8);
      final all = [...r1.pieces, ...r2.pieces].map((e) => e.id).toList();
      expect(all.toSet().length, 4);
      expect(all.any((e) => e.contains('#') || e == 'a'), isFalse);
    });
    test('özgün köşeler korunur, kesim başına en çok 2 sınır noktası', () {
      final a = line('a', n: 50); // x = 0, 10, ... 490
      final r = eraseArea(a, [p(245, 0)], 15);
      expect(r.pieces.length, 2);
      final total = r.pieces.fold<int>(0, (s, e) => s + e.points.length);
      final origKept = a.points.where((q) => (q.x - 245).abs() > 15).length;
      expect(total, lessThanOrEqualTo(origKept + 2));
      expect(total, greaterThanOrEqualTo(origKept));
      // özgün noktaların hepsi (silinmeyenler) aynen duruyor
      final xs = {for (final e in r.pieces) for (final q in e.points) q.x};
      for (final q in a.points.where((q) => (q.x - 245).abs() > 15)) {
        expect(xs, contains(q.x));
      }
    });
    test('art arda 10 silgi geçişinde nokta sayısı patlamaz', () {
      var strokes = [line('a', n: 50)];
      final start = strokes.single.points.length;
      for (var k = 0; k < 10; k++) {
        final cx = 30.0 + k * 45;
        strokes = [
          for (final s in strokes) ...eraseArea(s, [p(cx, 0)], 6).pieces,
        ];
      }
      final total = strokes.fold<int>(0, (s, e) => s + e.points.length);
      expect(total, lessThanOrEqualTo(start + 2 * 10 * 2));
      expect(total, lessThan(start + 40));
    });
    test('sınır noktasında baskı ve zaman doğrusal aradeğerlenir', () {
      final a = InkObject(id: 'a', points: [p(0, 0, 0, 0), p(100, 0, 1, 100)]);
      final r = eraseArea(a, [p(50, 0)], 10, idFor: (b, i) => '$b$i');
      expect(r.pieces.length, 2);
      final b0 = r.pieces[0].points.last; // ~x=40
      final b1 = r.pieces[1].points.first; // ~x=60
      expect(b0.x, closeTo(50 - 10 - a.halfWidth, 0.01));
      expect(b0.pressure, closeTo(b0.x / 100, 1e-9));
      expect(b0.tMs, closeTo(b0.x, 1e-9));
      expect(b1.x, closeTo(50 + 10 + a.halfWidth, 0.01));
      expect(b1.pressure, closeTo(b1.x / 100, 1e-9));
      expect(b1.tMs, closeTo(b1.x, 1e-9));
      expect(r.pieces[0].points.length, 2);
      expect(r.pieces[1].points.length, 2);
    });
    test('geçersiz yarıçap ArgumentError', () {
      for (final bad in [double.nan, double.infinity, -1.0]) {
        expect(() => eraseArea(line('a'), [p(5, 0)], bad), throwsArgumentError);
        expect(() => strokesTouchedByEraser([line('a')], [p(5, 0)], bad), throwsArgumentError);
      }
    });
  });
}
