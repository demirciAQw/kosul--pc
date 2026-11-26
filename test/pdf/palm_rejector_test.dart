import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/pen_diag.dart';
import 'package:kocum/features/pdf/domain/palm_rejector.dart';

PalmResult<int> _down(PalmRejector<int> r, int id, double t, double x, double y, {double rad = 100, bool passed = true}) =>
    r.touchDown(pointer: id, tMs: t, x: x, y: y, radius: rad, snapshot: id * 10, passed: passed);

void main() {
  test('kalem girince yakın ve yakın geçmişteki temas avuç; uzak ya da eski değil', () {
    final r = PalmRejector<int>();
    _down(r, 1, 0, 300, 300); // yakın + yeni
    _down(r, 2, 0, 1500, 300); // uzak
    final f = r.penEntered(tMs: 1000, x: 350, y: 350);
    expect([for (final t in f) t.pointer], [1]);
    expect(r.isPalm(2), isFalse);
    final r2 = PalmRejector<int>();
    _down(r2, 3, 0, 300, 300);
    expect(r2.penEntered(tMs: palmRecentMs + 1, x: 310, y: 310), isEmpty); // eski
  });

  test('geri alınacak anlık görüntü en eski temasınki; yutulmuş temas listeye girmez', () {
    final r = PalmRejector<int>();
    _down(r, 1, 100, 300, 300);
    _down(r, 2, 50, 320, 300);
    final f = r.penEntered(tMs: 500, x: 320, y: 320);
    expect(f.length, 2);
    expect(PalmRejector.restoreTarget<int>(f), 20);
    expect(r.anyPassedPalmDown, isTrue);
    r.touchUp(1);
    r.touchUp(2);
    expect(r.anyPassedPalmDown, isFalse);
    final q = PalmRejector<int>();
    _down(q, 4, 0, 300, 300, passed: false);
    expect(q.penEntered(tMs: 10, x: 300, y: 300), isEmpty);
    expect(q.isPalm(4), isTrue);
  });

  test('üç temas ya da büyük yarıçap anında avuç', () {
    final r = PalmRejector<int>();
    _down(r, 1, 0, 0, 0);
    _down(r, 2, 0, 900, 0);
    final x = _down(r, 3, 0, 0, 900);
    expect(x.selfPalm, isTrue);
    expect(x.flagged.length, 2);
    final b = _down(PalmRejector<int>(), 9, 0, 0, 0, rad: palmBigRadius);
    expect(b.selfPalm, isTrue);
  });

  test('PenDiag: kapalıyken yazmaz; açıkken biçim ve örnekleme', () {
    final lines = <String>[];
    PenDiag.sink = lines.add;
    PenDiag.enabled = false;
    void ev(String e) => PenDiag.log(e, tMs: 5, kind: 'stylus', device: 2, pointer: 7, x: 1, y: 2, pressure: .5, radiusMajor: 0, decision: PenDecision.penTook);
    ev('down');
    expect(lines, isEmpty);
    PenDiag.enabled = true;
    PenDiag.resetCounters();
    addTearDown(() => PenDiag.enabled = false);
    ev('down');
    expect(lines.single, 'KocumPen 5 down kind=stylus dev=2 ptr=7 pos=1.0,2.0 p=0.50 rMaj=0.0 karar=kalem-aldi');
    lines.clear();
    for (var i = 0; i < 25; i++) {
      ev('move');
    }
    expect(lines.length, 3); // 0., 10., 20.
    lines.clear();
    for (var i = 0; i < 41; i++) {
      ev('hover');
    }
    expect(lines.length, 3);
  });
}
