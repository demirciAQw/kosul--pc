import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/handwriting/domain/line_grouping.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';

import '_helpers.dart';

void main() {
  test('boş sayfa ve yalnız silinmiş çizgi: satır yok', () {
    expect(groupStrokesIntoLines(const []).lines, isEmpty);
    final r = groupStrokesIntoLines([box('a', 0, 0, 30, 40, deleted: true)]);
    expect(r.lines, isEmpty);
    expect(r.skippedIds, isEmpty); // silinmiş olan "atlanan" bile sayılmaz
  });

  test('iki ayrı satır: yukarıdan aşağı, her biri soldan sağa', () {
    // Çizgiler karışık sırada gelir (alttaki satır önce yazılmış gibi).
    final s = [...letters('b', 4, 300), ...letters('a', 5, 100)].reversed.toList();
    final r = groupStrokesIntoLines(s);
    expect(r.lines, hasLength(2));
    expect(r.lines[0].strokeIds, ['a0', 'a1', 'a2', 'a3', 'a4']);
    expect(r.lines[1].strokeIds, ['b0', 'b1', 'b2', 'b3']);
    expect(r.lines[0].top, lessThan(r.lines[1].top));
    expect(r.lines[0].bodyHeight, closeTo(40, 0.01));
  });

  test('bitişik satırlar: alt satırın yukarı uzanan harfi üsttekine değse de ayrı kalır', () {
    final top = letters('a', 4, 100); // 100..140
    final bottom = letters('b', 4, 150); // 150..190
    // Üst satırın "g" kuyruğu alt satırın kutusuna değer (120..155) ama merkezi üste yakın.
    final tail = box('tail', 130, 120, 20, 35);
    final r = groupStrokesIntoLines([...top, ...bottom, tail]);
    expect(r.lines, hasLength(2));
    expect(r.lines[0].strokeIds, contains('tail'));
    expect(r.lines.expand((l) => l.strokeIds).toSet(), hasLength(9));
  });

  test('küçük çizgiler (nokta, aksan) en yakın satıra bağlanır', () {
    final line = letters('a', 4, 100);
    final dot = box('dot', 140, 80, 4, 4); // "i" noktası: satırın hemen üstünde
    final comma = box('comma', 260, 142, 4, 8); // satır sonunda virgül
    final other = letters('b', 3, 300);
    final r = groupStrokesIntoLines([...line, dot, comma, ...other]);
    expect(r.lines, hasLength(2));
    expect(r.lines[0].strokeIds, containsAll(['dot', 'comma']));
    expect(r.lines[0].strokeIds, hasLength(6));
    // Satırın kutusu noktayı da kapsar.
    expect(r.lines[0].top, lessThanOrEqualTo(80));
  });

  test('uzakta kalan tek nokta kendi satırı olur', () {
    final r = groupStrokesIntoLines([...letters('a', 3, 100), box('far', 600, 900, 4, 4)]);
    expect(r.lines, hasLength(2));
    expect(r.lines[1].strokeIds, ['far']);
  });

  test('tek harf: tek satır', () {
    final r = groupStrokesIntoLines([box('x', 10, 10, 30, 40)]);
    expect(r.lines.single.strokes.single.id, 'x');
  });

  test('eğik yazı (sağa doğru yükselen) tek satır kalır', () {
    final s = [for (var i = 0; i < 20; i++) box('s$i', 100 + i * 40.0, 400 - i * 4.0, 30, 40)];
    final r = groupStrokesIntoLines(s);
    expect(r.lines, hasLength(1));
    expect(r.lines.single.strokes, hasLength(20));
  });

  test('yan yana kalmış iki parça tek satırda birleşir; üst üste satırlar birleşmez', () {
    // Sol ve sağ grup arada büyük boşlukla biraz kaymış; sıkı kümeleme ikiye böler, birleştirme toplar.
    final left = letters('l', 3, 100);
    final right = [for (var i = 0; i < 3; i++) box('r$i', 700 + i * 40.0, 114, 30, 40, at: 50 + i)];
    final r = groupStrokesIntoLines([...left, ...right], options: const GroupingOptions(bandFactor: 0.2));
    expect(r.lines, hasLength(1));
    // Aynı kaymayla ama x'te üst üste: iki satır olarak kalır.
    final stacked = [...letters('u', 3, 100), ...[for (var i = 0; i < 3; i++) box('v$i', 100 + i * 40.0, 114, 30, 40)]];
    expect(groupStrokesIntoLines(stacked, options: const GroupingOptions(bandFactor: 0.2)).lines, hasLength(2));
  });

  test('uzun düz çizgi, fosforlu ve silgi atlanır; şekil seçeneğe göre', () {
    final text = letters('a', 3, 100);
    final ruler = hline('ruler', 50, 900, 200);
    final hi = box('hi', 100, 100, 100, 40, tool: 'highlighter');
    final circle = box('circle', 300, 400, 200, 200, closed: true);
    final r = groupStrokesIntoLines([...text, ruler, hi, circle]);
    expect(r.lines, hasLength(1));
    expect(r.skippedIds, containsAll(['ruler', 'hi', 'circle']));

    final r2 = groupStrokesIntoLines([...text, circle], options: const GroupingOptions(markShapes: true));
    expect(r2.lines, hasLength(2));
    expect(r2.lines[1].isShape, isTrue);
    expect(r2.lines[1].strokeIds, ['circle']);
  });

  test('kısa düz çizgi (tire, "l") satırdan atılmaz', () {
    final r = groupStrokesIntoLines([...letters('a', 3, 100), hline('dash', 230, 260, 120)]);
    expect(r.lines.single.strokeIds, contains('dash'));
  });

  test('tanıyıcı girdisi: soldan sağa, artan zaman, satıra göre taşınmış, satır kadar yüksek alan', () {
    final r = groupStrokesIntoLines(letters('a', 3, 500, x0: 300, at: 1000));
    final ink = toRecognizerInk(r.lines.single);
    expect(ink.strokes, hasLength(3));
    final xs = [for (final s in ink.strokes) s.first.x];
    expect(xs, [...xs]..sort());
    var last = -1;
    for (final s in ink.strokes) {
      for (final p in s) {
        expect(p.t, greaterThanOrEqualTo(last));
        last = p.t;
      }
    }
    expect(ink.strokes.first.first.x, lessThan(20)); // sol-üste taşındı
    expect(ink.area.height, lessThan(120)); // sayfa değil, satır yüksekliği
    expect(ink.area.width, greaterThan(100));
  });

  test('zamansız (t=0) çizgide yapay artan zaman verilir', () {
    final s = InkStroke(
      id: 'z',
      owner: const NotePageOwner('p', 0),
      points: [for (var i = 0; i < 4; i++) StrokePoint(10 + i * 8.0, 10 + i * 10.0, t: 0)],
      startedAtMs: 0,
    );
    final ink = toRecognizerInk(groupStrokesIntoLines([s]).lines.single);
    final ts = [for (final p in ink.strokes.single) p.t];
    expect(ts, [...ts]..sort());
    expect(ts.toSet().length, ts.length);
  });
}
