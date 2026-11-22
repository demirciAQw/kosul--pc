import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/pdf/domain/ink_history.dart';
import 'package:kocum/features/pdf/domain/page_coords.dart';

PageCoords _c({
  double pw = 612,
  double ph = 792,
  double vw = 306,
  double vh = 396,
}) => PageCoords.tryCreate(
  pageWidth: pw,
  pageHeight: ph,
  viewWidth: vw,
  viewHeight: vh,
)!;

void main() {
  group('PageCoords', () {
    test('ölçek: yarım boyutlu görünümde köşeler ve orta', () {
      final c = _c();
      expect(c.toPage(Offset.zero), Offset.zero);
      expect(c.toPage(const Offset(306, 396)), const Offset(612, 792));
      expect(c.toPage(const Offset(153, 198)), const Offset(306, 396));
      expect(c.pageUnitsPerViewPx, 2);
      expect(c.viewPxPerPageUnit, 0.5);
    });

    test(
      'yakınlaştırma: aynı sayfa noktası her zumda aynı, gidiş-dönüş kaymaz',
      () {
        const page = Offset(123.4, 567.8);
        for (final zoom in [0.5, 1.0, 1.5, 3.0, 8.0]) {
          final c = _c(vw: 306 * zoom, vh: 396 * zoom);
          final v = c.toView(page);
          expect(v.dx, closeTo(page.dx * 0.5 * zoom, 1e-9));
          final back = c.toPage(v);
          expect(back.dx, closeTo(page.dx, 1e-9));
          expect(back.dy, closeTo(page.dy, 1e-9));
        }
      },
    );

    test('ekran noktası: sayfanın ekrandaki köşesi çıkarılır', () {
      final c = _c(vw: 612, vh: 792); // zum 1
      const origin = Offset(-40, 300); // sayfa kaydırılmış
      final p = c.screenToPage(const Offset(60, 400), origin);
      expect(p, const Offset(100, 100));
      expect(c.pageToScreen(p, origin), const Offset(60, 400));
    });

    test('döndürülmüş sayfa: en-boy yer değişir, çizgi aynı yerde kalır', () {
      expect(PageCoords.displayedSize(612, 792, 0), const Size(612, 792));
      expect(PageCoords.displayedSize(612, 792, 90), const Size(792, 612));
      expect(PageCoords.displayedSize(612, 792, 180), const Size(612, 792));
      expect(PageCoords.displayedSize(612, 792, 270), const Size(792, 612));
      expect(PageCoords.displayedSize(612, 792, -90), const Size(792, 612));
      expect(PageCoords.displayedSize(612, 792, 450), const Size(792, 612));
      // Yatay görünen sayfa (792x612) iki farklı zumda: sayfa noktası değişmez.
      final a = _c(pw: 792, ph: 612, vw: 396, vh: 306);
      final b = _c(pw: 792, ph: 612, vw: 1188, vh: 918);
      const p = Offset(700, 72);
      expect(a.toPage(a.toView(p)), p);
      expect(b.toPage(b.toView(p)), p);
      expect(b.toView(p), const Offset(1050, 108));
    });

    test('en-boy oranı biraz farklıysa eksenler ayrı ölçeklenir', () {
      final c = _c(vw: 306, vh: 400);
      expect(c.toPage(const Offset(306, 400)), const Offset(612, 792));
    });

    test('sıfır, negatif ve sonlu olmayan boyut null', () {
      for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          PageCoords.tryCreate(
            pageWidth: bad,
            pageHeight: 792,
            viewWidth: 100,
            viewHeight: 100,
          ),
          isNull,
        );
        expect(
          PageCoords.tryCreate(
            pageWidth: 612,
            pageHeight: bad,
            viewWidth: 100,
            viewHeight: 100,
          ),
          isNull,
        );
        expect(
          PageCoords.tryCreate(
            pageWidth: 612,
            pageHeight: 792,
            viewWidth: bad,
            viewHeight: 100,
          ),
          isNull,
        );
        expect(
          PageCoords.tryCreate(
            pageWidth: 612,
            pageHeight: 792,
            viewWidth: 100,
            viewHeight: bad,
          ),
          isNull,
        );
      }
    });
  });

  test('bölge görünümü: sol-üst başlangıcı sayfa koordinatına eklenir ve geri döner', () {
    // Sayfada (100, 200) başlayan 300x150'lik bölge, 600x300 pikselde (2x).
    final c = PageCoords.tryCreate(
      pageWidth: 300,
      pageHeight: 150,
      viewWidth: 600,
      viewHeight: 300,
      originX: 100,
      originY: 200,
    )!;
    expect(c.toPage(const Offset(0, 0)), const Offset(100, 200));
    expect(c.toPage(const Offset(600, 300)), const Offset(400, 350));
    expect(c.toView(const Offset(150, 225)), const Offset(100, 50));
    expect(c.pageUnitsPerViewPx, 0.5);
    expect(PageCoords.tryCreate(pageWidth: 1, pageHeight: 1, viewWidth: 1, viewHeight: 1, originX: double.nan), isNull);
  });

  group('InkHistory', () {
    test('geri al / yinele sırası, yeni eylem yinele yığınını boşaltır', () {
      final h = InkHistory();
      expect(h.canUndo, isFalse);
      h.push(const InkAction(InkActionKind.added, 0, ['a']));
      h.push(const InkAction(InkActionKind.erased, 1, ['b']));
      final u = h.takeUndo()!;
      expect(u.strokeIds, ['b']);
      h.commitUndo(u);
      expect(h.canRedo, isTrue);
      h.push(const InkAction(InkActionKind.added, 0, ['c']));
      expect(h.canRedo, isFalse);
      expect(h.takeUndo()!.strokeIds, ['c']);
      expect(h.takeUndo()!.strokeIds, ['a']);
      expect(h.takeUndo(), isNull);
    });

    test('boş eylem eklenmez, sınır aşılınca en eski düşer', () {
      final h = InkHistory(limit: 2);
      h.push(const InkAction(InkActionKind.added, 0, []));
      expect(h.canUndo, isFalse);
      for (final id in ['a', 'b', 'c']) {
        h.push(InkAction(InkActionKind.added, 0, [id]));
      }
      expect(h.takeUndo()!.strokeIds, ['c']);
      expect(h.takeUndo()!.strokeIds, ['b']);
      expect(h.takeUndo(), isNull);
    });
  });
}
