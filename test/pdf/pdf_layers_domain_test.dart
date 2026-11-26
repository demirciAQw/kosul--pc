import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/domain/page_layer.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart' show PdfBox;

PdfPageLayer _l(String id, int z, {PdfLayerKind kind = PdfLayerKind.full, int page = -1, PdfBox? box, bool deleted = false}) =>
    PdfPageLayer(id: id, documentId: 'd', page: page, kind: kind, box: box, z: z, deleted: deleted);

void main() {
  test('katmanlar z sırasıyla 1den numaralanır, silinenler atlanır', () {
    final o = orderLayers([_l('b', 2), _l('a', 1), _l('x', 0, deleted: true), _l('c', 2)]);
    expect([for (final l in o) '${l.number}${l.id}'], ['1a', '2b', '3c']);
  });

  test('görüntü sırası order ile belirlenir, çizgi anahtarı z ile sabit kalır', () {
    // z: a=0, b=1, c=2; b öne alındı (order -1 gibi küçük bir değer).
    final ls = [_l('a', 0), _l('b', 1).withParams({'order': -1}), _l('c', 2)];
    final o = orderLayers(ls);
    expect([for (final l in o) l.id], ['b', 'a', 'c']);
    expect([for (final l in o) l.number], [1, 2, 3]);
    expect([for (final l in o) l.key], [2, 1, 3]); // z + 1: sıra değişse de aynı
  });

  test('silinen katman numaraları sıkıştırır; anahtarlar kalıcı', () {
    final o = orderLayers([_l('a', 0), _l('b', 1, deleted: true), _l('c', 2)]);
    expect([for (final l in o) l.number], [1, 2]);
    expect(layerKeyForNumber(o, 2), 3);
    expect(layerNumberForKey(o, 3), 2);
    expect(layerNumberForKey(o, 2), isNull); // silinmiş katmanın anahtarı
    expect(layerKeyForNumber(o, 0), 0);
    expect(layerNumberForKey(o, 0), 0);
  });

  test('moveLayerOrders komşuyla yer değiştirir, sınırda null', () {
    final o = orderLayers([_l('a', 0), _l('b', 1), _l('c', 2)]);
    expect(moveLayerOrders(o, 2, -1), {'b': 0, 'a': 1, 'c': 2});
    expect(moveLayerOrders(o, 2, 1), {'a': 0, 'c': 1, 'b': 2});
    expect(moveLayerOrders(o, 1, -1), isNull);
    expect(moveLayerOrders(o, 3, 1), isNull);
    // uygulanınca z (anahtar) değişmez
    final moved = orderLayers([for (final l in o) l.withParams({'order': moveLayerOrders(o, 3, -1)![l.id]})]);
    expect([for (final l in moved) l.id], ['a', 'c', 'b']);
    expect([for (final l in moved) l.key], [1, 3, 2]);
  });

  test('soru katmanı bölge dışı çizgiyi reddeder', () {
    final q = _l('q', 1, kind: PdfLayerKind.question, page: 2, box: const PdfBox(10, 10, 100, 100));
    expect(layerAccepts(q, 2, const Offset(50, 50)), isTrue);
    expect(layerAccepts(q, 2, const Offset(150, 50)), isFalse);
    expect(layerAccepts(q, 1, const Offset(50, 50)), isFalse);
    expect(layerAccepts(_l('f', 1), 5, const Offset(500, 500)), isTrue);
    expect(layerAccepts(null, 0, Offset.zero), isTrue);
  });

  test('eski kind değerleri yok sayılır; parametre varsayılanları', () {
    expect(PdfLayerKind.parse('watermark'), isNull);
    expect(PdfLayerKind.parse('question'), PdfLayerKind.question);
    final l = _l('a', 0).withParams({'buttonX': 5, 'buttonY': 7, 'note': 'x'});
    expect(l.buttonAt, const Offset(5, 7));
    expect(l.note, 'x');
    expect(l.opacity, 1.0);
    expect(l.color, 0xFFFFFFFF);
  });
}
