import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/solve.dart';

StrokeTime st(int start, int dur, {int attempt = 1}) =>
    StrokeTime(attemptNo: attempt, startedAtMs: start, durationMs: dur);

void main() {
  group('deneme listesi', () {
    test('denemelere böler, sıralar, 1\'den küçüğü atlar', () {
      final a = solveAttempts([st(1000, 500, attempt: 2), st(1000, 700), st(5000, 300), st(9, 9, attempt: 0)]);
      expect(a.map((e) => (e.no, e.strokeCount)), [(1, 2), (2, 1)]);
      expect(solveAttempts(const []), isEmpty);
    });
    test('sonraki ve açılış denemesi', () {
      expect(nextAttemptNo(const []), 1);
      expect(nextAttemptNo([1, 3, 2]), 4);
      expect(currentAttemptNo(const []), 1);
      expect(currentAttemptNo([1, 2]), 2);
      expect(defaultOldAttempt([1, 2, 3], 3), 2);
      expect(defaultOldAttempt([3], 3), isNull);
      expect(defaultOldAttempt(const [], 1), isNull);
    });
  });

  group('solveDuration', () {
    test('boş liste ve tek çizgi', () {
      expect(solveDuration(const []), Duration.zero);
      expect(solveDuration([st(1000, 1500)]), const Duration(milliseconds: 1500));
    });
    test('çakışan aralıklar birleşir (iki kez sayılmaz)', () {
      // [1000,3000] ve [2000,4000] -> [1000,4000]
      expect(solveDuration([st(2000, 2000), st(1000, 2000)]), const Duration(seconds: 3));
      // içinde kalan çizgi
      expect(solveDuration([st(1000, 5000), st(2000, 500)]), const Duration(seconds: 5));
    });
    test('kısa boşluk sayılır, uzun duraklama sayılmaz', () {
      // 1 sn çizgi, 10 sn boşluk (sayılır), 1 sn çizgi = 12 sn
      expect(solveDuration([st(1000, 1000), st(12000, 1000)]), const Duration(seconds: 12));
      // 1 sn çizgi, 60 sn boşluk (mola), 1 sn çizgi = 2 sn
      expect(solveDuration([st(1000, 1000), st(62000, 1000)]), const Duration(seconds: 2));
      // eşik parametre: 5 sn
      expect(solveDuration([st(1000, 1000), st(12000, 1000)], maxGap: const Duration(seconds: 5)), const Duration(seconds: 2));
      // tam eşik sayılır
      expect(solveDuration([st(0 + 1, 1000), st(31001, 1000)]), const Duration(seconds: 32));
    });
    test('bozuk veri: negatif süre, geçersiz başlangıç, aşırı uzun çizgi', () {
      expect(solveDuration([st(1000, -500)]), Duration.zero);
      expect(solveDuration([st(0, 1000), st(-5, 1000)]), Duration.zero);
      expect(solveDuration([st(1000, 99 * 60 * 1000)]), defaultMaxStroke);
      // sırasız gelse de aynı sonuç
      expect(
        solveDuration([st(12000, 1000), st(1000, 1000)]),
        solveDuration([st(1000, 1000), st(12000, 1000)]),
      );
    });
    test('deneme başına süre ayrı hesaplanır', () {
      final a = solveAttempts([st(1000, 1000), st(500000, 2000, attempt: 2)]);
      expect(a.map((e) => e.duration.inSeconds), [1, 2]);
    });
  });

  test('süre biçimi', () {
    expect(formatSolveDuration(Duration.zero), '0 sn');
    expect(formatSolveDuration(const Duration(seconds: 45)), '45 sn');
    expect(formatSolveDuration(const Duration(seconds: 130)), '2 dk 10 sn');
    expect(formatSolveDuration(const Duration(minutes: 3)), '3 dk');
  });

  group('çizim bölgesi', () {
    const page = PdfPageSize(600, 800);
    test('kutunun çevresi, sağda ve altta pay; sol/üst/sağ sayfaya kırpılır, alt taşabilir', () {
      final r = solveRegion(const PdfBox(100, 200, 300, 400), page)!;
      expect((r.left, r.top), (88, 188));
      expect(r.right, 300 + 12 + 200 * 0.3);
      expect(r.bottom, greaterThan(400 + 200)); // en az kutu yüksekliği kadar alt pay
      final edge = solveRegion(const PdfBox(5, 5, 590, 790), page)!;
      expect((edge.left, edge.top, edge.right), (0, 0, 600));
      expect(edge.bottom, greaterThan(800)); // sayfa dışına taşar
    });
    test('küçük kutuda en az minBelow', () {
      final r = solveRegion(const PdfBox(100, 100, 200, 130), page)!;
      expect(r.bottom, 130 + 12 + 160);
    });
    test('geçersiz kutu ya da sayfa: null', () {
      expect(solveRegion(const PdfBox(10, 10, 10, 50), page), isNull);
      expect(solveRegion(const PdfBox(double.nan, 0, 5, 5), page), isNull);
      expect(solveRegion(const PdfBox(0, 0, 5, 5), const PdfPageSize(0, 10)), isNull);
    });
  });

  group('katman planı', () {
    test('varsayılan: yalnızca yazılabilir güncel deneme', () {
      expect(planSolveLayers(current: 2, existing: [1, 2]), [const SolveLayerSpec(2, opacity: 1, editable: true)]);
    });
    test('eski çözüm açık: altta saydam gri, üstte güncel', () {
      final p = planSolveLayers(current: 3, existing: [1, 2], showOld: true, old: 2, oldOpacity: 0.3);
      expect(p, [
        const SolveLayerSpec(2, opacity: 0.3, tint: oldAttemptTint),
        const SolveLayerSpec(3, opacity: 1, editable: true),
      ]);
    });
    test('eski çözüm geçersizse (yok, güncelle aynı, seçilmemiş) gösterilmez', () {
      for (final old in [null, 3, 9]) {
        expect(planSolveLayers(current: 3, existing: [1, 2, 3], showOld: true, old: old).length, 1);
      }
      expect(planSolveLayers(current: 3, existing: [1, 2], old: 2).length, 1);
    });
    test('saydamlık sınırlanır; NaN varsayılana döner', () {
      expect(clampOldOpacity(0), minOldOpacity);
      expect(clampOldOpacity(7), 1);
      expect(clampOldOpacity(double.nan), defaultOldOpacity);
    });
    test('üst üste bindirme: iki renk, salt okunur; aynıysa tek', () {
      final p = planSolveLayers(current: 3, existing: [1, 2], compare: (1, 2));
      expect(p, [
        const SolveLayerSpec(1, opacity: compareOpacity, tint: compareTintA),
        const SolveLayerSpec(2, opacity: compareOpacity, tint: compareTintB),
      ]);
      expect(p.any((e) => e.editable), isFalse);
      expect(planSolveLayers(current: 3, existing: [1], compare: (1, 1)).length, 1);
    });
  });
}
