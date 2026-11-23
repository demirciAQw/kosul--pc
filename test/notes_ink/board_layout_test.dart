import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/notes/domain/board_layout.dart';
import 'package:kocum/features/notes/domain/ink_folder.dart';
import 'package:kocum/features/notes/domain/page_board.dart';
import 'package:kocum/features/notes/domain/page_item_geometry.dart';

void expectNoOverlap(Map<String, BoardRect> m) {
  final e = m.entries.toList();
  for (var i = 0; i < e.length; i++) {
    for (var j = i + 1; j < e.length; j++) {
      expect(e[i].value.overlaps(e[j].value), isFalse, reason: '${e[i].key} ${e[i].value} x ${e[j].key} ${e[j].value}');
    }
  }
}

void main() {
  group('layoutTree', () {
    test('tek kök + iki çocuk: ebeveyn ortalanır, çocuklar alt sırada yan yana', () {
      final m = layoutTree(const [TreeNode('r', null), TreeNode('a', 'r', sortOrder: 0), TreeNode('b', 'r', sortOrder: 1)]);
      expect(m['a']!.y, m['b']!.y);
      expect(m['a']!.y, greaterThan(m['r']!.bottom));
      expect(m['a']!.x, lessThan(m['b']!.x));
      expect(m['r']!.cx, closeTo((m['a']!.cx + m['b']!.cx) / 2, 1e-9));
      expect(m['b']!.x - m['a']!.right, 80); // yatay boşluk
      expectNoOverlap(m);
    });

    test('derin ve geniş ağaç: hiçbir kart çakışmaz', () {
      final nodes = <TreeNode>[const TreeNode('ders', null)];
      for (var u = 0; u < 7; u++) {
        nodes.add(TreeNode('u$u', 'ders', sortOrder: u));
        for (var k = 0; k < (u % 4); k++) {
          nodes.add(TreeNode('u$u.k$k', 'u$u', sortOrder: k));
          if (k == 1) nodes.add(TreeNode('u$u.k$k.z', 'u$u.k$k'));
        }
      }
      final m = layoutTree(nodes);
      expect(m, hasLength(nodes.length));
      expectNoOverlap(m);
      expect(m.values.every((r) => r.x >= 0 && r.y >= 0), isTrue);
    });

    test('sortOrder sırayı belirler; boyut verilen düğüm kendi boyutunu alır', () {
      final m = layoutTree(const [TreeNode('r', null), TreeNode('b', 'r', sortOrder: 2), TreeNode('a', 'r', sortOrder: 1, w: 600, h: 200)]);
      expect(m['a']!.x, lessThan(m['b']!.x));
      expect((m['a']!.w, m['a']!.h), (600.0, 200.0));
      expectNoOverlap(m);
    });

    test('genişlik: çocuksuz geniş ebeveyn komşusunu ezmez; bilinmeyen ebeveyn kök sayılır', () {
      final m = layoutTree(const [TreeNode('p', null, w: 1000), TreeNode('c', 'p'), TreeNode('q', 'yok')]);
      expectNoOverlap(m);
      expect(m['q']!.y, 0);
    });

    test('döngülü bozuk veri: sonsuz döngü yok, her düğüm yerleşir', () {
      final m = layoutTree(const [TreeNode('a', 'b'), TreeNode('b', 'a'), TreeNode('c', 'c')]);
      expect(m.keys.toSet(), {'a', 'b', 'c'});
      expectNoOverlap(m);
    });

    test('boş liste', () => expect(layoutTree(const []), isEmpty));
  });

  group('autoArrange', () {
    BoardCard c(String id, {double? w, double? h}) => BoardCard(pageId: id, notebookId: 'n', pageNo: 0, w: w, h: h);

    test('bağlantısızlar ızgara, bağlantılılar ağaç; çakışma yok', () {
      final pages = [c('a'), c('b'), c('c'), c('x'), c('y'), c('z'), c('w')];
      final m = autoArrange(pages, [(from: 'a', to: 'b'), (from: 'a', to: 'c')]);
      expect(m, hasLength(7));
      expectNoOverlap(m);
      expect(m['a']!.y, lessThan(m['b']!.y));
      // ızgara ağacın altında
      final treeBottom = [m['a']!, m['b']!, m['c']!].map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      for (final id in ['x', 'y', 'z', 'w']) {
        expect(m[id]!.y, greaterThanOrEqualTo(treeBottom));
      }
      // 4 bağsız: 2x2 ızgara
      expect({m['x']!.y, m['y']!.y, m['z']!.y, m['w']!.y}, hasLength(2));
    });

    test('hiç bağlantı yok: yalnız ızgara; döngü kapatan ve geçersiz bağlantılar yok sayılır', () {
      expect(autoArrange([c('a'), c('b'), c('c')], const []), hasLength(3));
      final m = autoArrange([c('a'), c('b')], [(from: 'a', to: 'b'), (from: 'b', to: 'a'), (from: 'a', to: 'a'), (from: 'a', to: 'yok')]);
      expect(m['a']!.y, lessThan(m['b']!.y));
      expectNoOverlap(m);
    });
  });

  group('edgePoints', () {
    test('yan yana kartlar: sağ-orta ile sol-orta', () {
      const a = BoardRect(0, 0, 100, 100), b = BoardRect(300, 0, 100, 100);
      final e = edgePoints(a, b);
      expect((e.from, e.to), (const BoardPoint(100, 50), const BoardPoint(300, 50)));
    });
    test('alt alta: alt-orta ile üst-orta', () {
      const a = BoardRect(0, 0, 100, 100), b = BoardRect(0, 300, 100, 100);
      final e = edgePoints(a, b);
      expect((e.from, e.to), (const BoardPoint(50, 100), const BoardPoint(50, 300)));
    });
    test('çapraz: en yakın iki kenar noktası; yön tersine simetrik', () {
      const a = BoardRect(0, 0, 100, 100), b = BoardRect(200, 250, 100, 100);
      final e = edgePoints(a, b), r = edgePoints(b, a);
      expect((e.from, e.to), (r.to, r.from));
      final d = (e.from.x - e.to.x) * (e.from.x - e.to.x) + (e.from.y - e.to.y) * (e.from.y - e.to.y);
      expect(d, 62500); // (50,100) ile (250,250) / (200,300): daha kısası yok
    });
  });

  test('freeSlotNear: ebeveynin sağı, doluysa aşağı', () {
    const p = BoardRect(0, 0, 320, 420);
    final first = freeSlotNear(p, const []);
    expect((first.x, first.y), (400.0, 0.0));
    final second = freeSlotNear(p, [first]);
    expect(second.x, 400.0);
    expect(second.y, greaterThan(first.bottom));
    expect(second.overlaps(first), isFalse);
  });

  group('klasör saf kuralları', () {
    final parentOf = <String, String?>{'a': null, 'b': 'a', 'c': 'b', 'd': null};
    test('döngü kontrolü', () {
      expect(wouldCreateFolderCycle('a', 'a', parentOf), isTrue);
      expect(wouldCreateFolderCycle('a', 'c', parentOf), isTrue);
      expect(wouldCreateFolderCycle('c', 'a', parentOf), isFalse);
      expect(wouldCreateFolderCycle('a', null, parentOf), isFalse);
      expect(wouldCreateFolderCycle('d', 'c', parentOf), isFalse);
      expect(wouldCreateFolderCycle('x', 'p', {'p': 'q', 'q': 'p'}), isFalse); // bozuk veri takmaz
    });
    test('yol; bozuk döngü keser', () {
      expect(folderPath('c', parentOf), ['a', 'b', 'c']);
      expect(folderPath('d', parentOf), ['d']);
      expect(folderPath('p', {'p': 'q', 'q': 'p'}), hasLength(2));
    });
  });

  group('öğe geometrisi', () {
    test('clampItemRect: taşanı içeri alır, büyüğü küçültür, NaN güvenli', () {
      expect(clampItemRect(const BoardRect(-50, 900, 200, 200), 1000, 1000), const BoardRect(0, 800, 200, 200));
      expect(clampItemRect(const BoardRect(0, 0, 5000, 10), 1000, 1000), const BoardRect(0, 0, 1000, 24));
      final n = clampItemRect(BoardRect(double.nan, 0, double.nan, 50), 1000, 1000);
      expect((n.x, n.w), (0.0, 24.0));
    });
    test('resizeItemRect: karşı kenar sabit, asgari boyut, ters dönmez', () {
      const r = BoardRect(100, 100, 200, 100);
      var o = resizeItemRect(r, ResizeHandle.right, 50, 999);
      expect((o.x, o.y, o.w, o.h), (100.0, 100.0, 250.0, 100.0));
      o = resizeItemRect(r, ResizeHandle.left, 1000, 0);
      expect(o.right, 300);
      expect(o.w, minItemSize);
      o = resizeItemRect(r, ResizeHandle.topLeft, -20, -10);
      expect((o.right, o.bottom, o.w, o.h), (300.0, 200.0, 220.0, 110.0));
    });
    test('resizeItemRect: oran korunur; sayfaya sığar', () {
      const r = BoardRect(100, 100, 200, 100); // 2:1
      final o = resizeItemRect(r, ResizeHandle.bottomRight, 100, 0, keepAspect: true);
      expect(o.w / o.h, closeTo(2, 1e-9));
      expect((o.x, o.y), (100.0, 100.0));
      final big = resizeItemRect(r, ResizeHandle.bottomRight, 5000, 5000, keepAspect: true, pageW: 1000, pageH: 1000);
      expect(big.right, lessThanOrEqualTo(1000));
      expect(big.bottom, lessThanOrEqualTo(1000));
      expect(big.w / big.h, closeTo(2, 1e-6));
    });
    test('fitWithin ve defaultImageRect', () {
      expect(fitWithin(4000, 3000), (w: 2048, h: 1536));
      expect(fitWithin(1000, 500), (w: 1000, h: 500));
      expect(fitWithin(3000, 4000, maxSide: 1000), (w: 750, h: 1000));
      expect(fitWithin(10000, 1), (w: 2048, h: 1));
      final d = defaultImageRect(2000, 1000, 1000, 1400);
      expect((d.w, d.h, d.cx, d.cy), (500.0, 250.0, 500.0, 700.0));
    });
  });

  group('görsel yolu', () {
    test('geçerli yol aktarım kuralına uyar', () {
      final p = pageImagePath(DateTime(2026, 11, 3), '0190-abc_DEF', '.WEBP');
      expect(p, 'notes/2026/11/0190-abc_DEF.webp');
      expect(isPageImagePath(p), isTrue);
    });
    test('geçersizler reddedilir', () {
      expect(() => pageImagePath(DateTime(2026, 1, 1), '../x', 'png'), throwsArgumentError);
      expect(() => pageImagePath(DateTime(2026, 1, 1), 'a', 'p/ng'), throwsArgumentError);
      expect(() => pageImagePath(DateTime(2026, 1, 1), 'a', 'uzunuzantiyok'), throwsArgumentError);
      for (final bad in ['questions/2026/11/a.webp', '/notes/2026/11/a.webp', 'notes/2026/11/../a.webp', 'notes/26/11/a.webp', 'notes/2026/11/a/b.webp', 'a.webp']) {
        expect(isPageImagePath(bad), isFalse, reason: bad);
      }
    });
  });

  group('yükler', () {
    test('metin yükü gidiş-dönüş; bozuk JSON varsayılan', () {
      const t = TextItemPayload(text: 'merhaba "dünya"', fontSize: 40, color: 0xFFFF0000, bold: true, italic: true, align: 'center');
      final back = TextItemPayload.fromJson(t.toJson());
      expect((back.text, back.fontSize, back.color, back.bold, back.italic, back.align), (t.text, 40.0, 0xFFFF0000, true, true, 'center'));
      expect(TextItemPayload.fromJson('{bozuk').text, '');
      expect(TextItemPayload.fromJson(null).align, 'left');
      expect(TextItemPayload.fromJson('{"align":"x"}').align, 'left');
    });
    test('görsel yükü: saydamlık 0..1 kırpılır', () {
      expect(ImageItemPayload.fromJson('{"pxW":10,"pxH":20,"alpha":5}').alpha, 1.0);
      expect(ImageItemPayload.fromJson(const ImageItemPayload(pxW: 3, pxH: 4, alpha: 0.5).toJson()).pxH, 4);
      expect(ImageItemPayload.fromJson('[]').pxW, 0);
    });
  });
}
