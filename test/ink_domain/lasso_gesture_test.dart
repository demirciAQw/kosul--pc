import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/ink/domain/ink_object.dart';
import 'package:kocum/features/ink/domain/lasso_gesture.dart';

InkObject line(String id, double x0, double y0, double x1, double y1) => InkObject(
  id: id,
  points: [InkPoint(x: x0, y: y0, pressure: 0.6), InkPoint(x: x1, y: y1, pressure: 0.6)],
  brush: const InkBrush(width: 2),
);

const box = InkRect(100, 100, 200, 160);

void main() {
  test('tutamak isabeti: köşe, kenar, döndürme, gövde, dışarısı', () {
    LassoHandle? h(double x, double y) => hitLassoHandle(box, x, y, tol: 8);
    expect(h(100, 100), LassoHandle.topLeft);
    expect(h(203, 163), LassoHandle.bottomRight);
    expect(h(150, 99), LassoHandle.top);
    expect(h(200, 130), LassoHandle.right);
    expect(h(150, 100 - 28), LassoHandle.rotate);
    expect(h(150, 130), LassoHandle.body);
    expect(h(400, 400), isNull);
    expect(LassoHandle.values.where((e) => e != LassoHandle.body && e != LassoHandle.rotate), hasLength(8));
  });

  test('ince kutuda kenar tutamacı gövdeyi örtmez; köşeler çalışır', () {
    const thin = InkRect(100, 100, 400, 108); // tek çizgi yazı
    expect(hitLassoHandle(thin, 250, 104, tol: 16), LassoHandle.body);
    expect(hitLassoHandle(thin, 100, 100, tol: 16), LassoHandle.topLeft);
    expect(hitLassoHandle(thin, 100, 104, tol: 16), LassoHandle.topLeft); // sol kenar da kapalı değil ama köşe önde
    expect(isHandleUsable(thin, LassoHandle.top, tol: 16), isFalse);
    expect(isHandleUsable(thin, LassoHandle.right, tol: 16), isTrue);
  });

  test('gövde sürükleme taşır', () {
    final d = LassoDrag(LassoHandle.body, box, 150, 130);
    final r = d.apply([line('a', 110, 110, 190, 150)], 170, 120).single;
    expect(r.points[0].x, 130);
    expect(r.points[0].y, 100);
    expect(r.points[1].x, 210);
    expect(r.points[0].pressure, 0.6);
  });

  test('köşe tutamacı orantılı büyütür; karşı köşe sabit', () {
    final o = line('a', 100, 100, 200, 160);
    final d = LassoDrag(LassoHandle.bottomRight, box, 200, 160);
    final r = d.apply([o], 300, 220).single; // 2x
    expect(r.points[0].x, closeTo(100, 1e-9));
    expect(r.points[0].y, closeTo(100, 1e-9));
    expect(r.points[1].x, closeTo(300, 1e-9));
    expect(r.points[1].y, closeTo(220, 1e-9));
    // Sol-üst köşeden küçültme: sağ-alt sabit, oran korunur.
    final r2 = LassoDrag(LassoHandle.topLeft, box, 100, 100).apply([o], 150, 100).single;
    expect(r2.points[1].x, closeTo(200, 1e-9));
    expect(r2.points[1].y, closeTo(160, 1e-9));
    final w = r2.points[1].x - r2.points[0].x, h = r2.points[1].y - r2.points[0].y;
    expect(w / h, closeTo(100 / 60, 1e-9));
  });

  test('kenar tutamacı tek eksende uzatır', () {
    final o = line('a', 100, 100, 200, 160);
    final r = LassoDrag(LassoHandle.right, box, 200, 130).apply([o], 300, 500).single;
    expect(r.points[1].x, closeTo(300, 1e-9));
    expect(r.points[1].y, closeTo(160, 1e-9));
    final r2 = LassoDrag(LassoHandle.top, box, 150, 100).apply([o], 0, 130).single;
    expect(r2.points[0].y, closeTo(130, 1e-9));
    expect(r2.points[1].y, closeTo(160, 1e-9));
  });

  test('sıfır ve ters ölçek korunur: kutu en az %2, çizgi tek noktaya çökmez, ters dönmez', () {
    final o = line('a', 100, 100, 200, 160);
    // Karşı köşenin ötesine sürükle: ters dönme yok, en küçük orana iner.
    final r = LassoDrag(LassoHandle.bottomRight, box, 200, 160).apply([o], 50, 50).single;
    final w = r.points[1].x - r.points[0].x;
    expect(w, greaterThan(0));
    expect(w, closeTo(100 * LassoDrag.minRatio, 1e-6));
    expect(r.points.every((p) => p.x.isFinite && p.y.isFinite), isTrue);
  });

  test('döndürme: üst tutamaç sağa alınınca 90 derece; merkez sabit; ardışık uygulama birikmez', () {
    final o = line('a', 100, 130, 200, 130); // yatay, merkezden geçer
    final d = LassoDrag(LassoHandle.rotate, box, 150, 72);
    // Merkez (150,130); başlangıç yönü yukarı; (250,130) = sağ → +90 derece.
    final r = d.apply([o], 250, 130).single;
    expect(r.points[0].x, closeTo(150, 1e-6));
    expect(r.points[0].y, closeTo(80, 1e-6));
    expect(r.points[1].y, closeTo(180, 1e-6));
    d.apply([o], 300, 300); // ara kare
    final r2 = d.apply([o], 250, 130).single;
    expect(r2.points[0].x, closeTo(150, 1e-6));
  });

  test('offsetObjects kimlik ve baskıyı korur', () {
    final r = offsetObjects([line('a', 0, 0, 10, 10)], 5, 7).single;
    expect((r.id, r.points[0].x, r.points[0].y, r.points[0].pressure), ('a', 5, 7, 0.6));
  });

  group('ince seçim ve sayfa sınırı', () {
    const page = InkRect(0, 0, 1000, 1000);
    // Yatay çizgi: yükseklik 0.
    final hl = line('h', 100, 500, 400, 500);
    const hbox = InkRect(100, 500, 400, 500);

    test('ince yatay seçimde köşe sürüklemesi ölçeği patlatmaz', () {
      // Eski max(rx, ry): dikey sürükleme (500 birim aşağı) ry = 500/1e-6 olurdu.
      final d = LassoDrag(LassoHandle.bottomRight, hbox, 400, 500);
      final r = d.apply([hl], 400, 1000).single;
      final w = r.points[1].x - r.points[0].x;
      expect(w, lessThanOrEqualTo(300 * LassoDrag.maxRatio + 1e-6));
      expect(w, greaterThanOrEqualTo(300 * LassoDrag.minRatio - 1e-6));
      expect(w, closeTo(300, 1)); // dikey sürükleme yataya neredeyse etki etmez
      // Yatay sürükleme düzgün orantılı büyütür.
      final r2 = d.apply([hl], 700, 500).single;
      expect(r2.points[1].x - r2.points[0].x, closeTo(600, 1e-6));
    });

    test('ölçek üst sınırı 20', () {
      final d = LassoDrag(LassoHandle.bottomRight, box, 200, 160);
      final r = d.apply([line('a', 100, 100, 200, 160)], 1e9, 1e9).single;
      expect(r.points[1].x - r.points[0].x, closeTo(100 * LassoDrag.maxRatio, 1e-6));
      // Alt sınır: ters yöne sürükleme sıfıra/negatife inmez.
      final r2 = d.apply([line('a', 100, 100, 200, 160)], -500, -500).single;
      expect(r2.points[1].x - r2.points[0].x, closeTo(100 * LassoDrag.minRatio, 1e-6));
    });

    test('köşe boyutlandırma sayfa sınırında durur', () {
      final d = LassoDrag(LassoHandle.bottomRight, hbox, 400, 500, pageBounds: page);
      final r = d.apply([hl], 5000, 5000).single;
      expect(r.points[1].x, lessThanOrEqualTo(1000 + 1e-6));
      final e = LassoDrag(LassoHandle.right, hbox, 400, 500, pageBounds: page);
      expect(e.apply([hl], 9000, 500).single.points[1].x, lessThanOrEqualTo(1000 + 1e-6));
    });

    test('taşıma sayfa sınırına kıstırılır; dışarıdaki kutu içeri zorlanmaz', () {
      final d = LassoDrag(LassoHandle.body, hbox, 250, 500, pageBounds: page);
      final r = d.apply([hl], 250 + 5000, 500 - 5000).single;
      expect(r.points[1].x, closeTo(1000, 1e-6)); // sağa dayandı
      expect(r.points[0].y, closeTo(0, 1e-6)); // üste dayandı
      final l = d.apply([hl], 250 - 5000, 500).single;
      expect(l.points[0].x, closeTo(0, 1e-6));
      // Kutu zaten sayfa dışında: daha da dışarı gitmez, içeri atlamaz.
      const outBox = InkRect(900, 500, 1200, 500);
      final out = line('o', 900, 500, 1200, 500);
      final o = LassoDrag(LassoHandle.body, outBox, 1000, 500, pageBounds: page);
      expect(o.apply([out], 1100, 500).single.points[0].x, closeTo(900, 1e-6)); // sağa gidemez
      expect(o.apply([out], 800, 500).single.points[0].x, closeTo(700, 1e-6)); // sola serbest
    });
  });
}
