import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/notes/domain/page_template.dart';

void main() {
  test('anahtar çevirisi; bilinmeyen anahtar düz sayfa olur', () {
    for (final t in PageTemplate.values) {
      expect(PageTemplate.fromKey(t.key), t);
    }
    expect(PageTemplate.fromKey('baska'), PageTemplate.plain);
    expect(PageTemplate.fromKey(null), PageTemplate.plain);
  });

  test('düz: çizgi yok', () {
    expect(templateLines(PageTemplate.plain, 1404, 1984).isEmpty, isTrue);
  });

  test('çizgili: yalnızca yatay, eşit aralık, üst boşluk iki aralık, alta taşmaz', () {
    final l = templateLines(PageTemplate.ruled, 1404, 1984);
    final step = defaultTemplateSpacing(1404);
    expect(step, closeTo(56.16, 1e-9));
    expect(l.vertical, isEmpty);
    expect(l.horizontal.first, closeTo(step * 2, 1e-9));
    expect(l.horizontal.last, lessThanOrEqualTo(1984 - step + 1e-6));
    expect(l.horizontal.last + step, greaterThan(1984 - step));
    for (var i = 1; i < l.horizontal.length; i++) {
      expect(l.horizontal[i] - l.horizontal[i - 1], closeTo(step, 1e-9));
    }
  });

  test('aralık genişliğe göre ölçeklenir; açık aralık verilebilir', () {
    final small = templateLines(PageTemplate.ruled, 702, 992);
    final big = templateLines(PageTemplate.ruled, 1404, 1984);
    expect(small.horizontal.length, big.horizontal.length); // oran aynı
    expect(small.horizontal.first * 2, closeTo(big.horizontal.first, 1e-9));
    final custom = templateLines(PageTemplate.ruled, 1000, 500, spacing: 100);
    expect(custom.horizontal, [200, 300, 400]);
  });

  test('kareli: iki yönde ortalı, kenara çizgi yok, eşit aralık', () {
    final l = templateLines(PageTemplate.grid, 1000, 700, spacing: 100);
    expect(l.vertical, [for (var i = 1; i <= 9; i++) i * 100.0]); // 0 ve 1000 kenarı çizilmez
    expect(l.horizontal, [for (var i = 1; i <= 6; i++) i * 100.0]);
    final odd = templateLines(PageTemplate.grid, 1050, 700, spacing: 100);
    expect(odd.vertical.first, closeTo(25, 1e-9)); // (1050-1000)/2
    expect(1050 - odd.vertical.last, closeTo(25 + 0, 1e-9));
    expect(odd.vertical.length, 11);
    final a4 = templateLines(PageTemplate.grid, 1404, 1984);
    expect(a4.vertical, isNotEmpty);
    expect(a4.horizontal.every((y) => y > 0 && y < 1984), isTrue);
    expect(a4.vertical.every((x) => x > 0 && x < 1404), isTrue);
  });

  test('geçersiz boyut ve aralık ArgumentError', () {
    expect(() => templateLines(PageTemplate.ruled, 0, 100), throwsArgumentError);
    expect(() => templateLines(PageTemplate.ruled, 100, -1), throwsArgumentError);
    expect(() => templateLines(PageTemplate.grid, 100, 100, spacing: 0), throwsArgumentError);
    expect(() => templateLines(PageTemplate.grid, double.nan, 100), throwsArgumentError);
  });

  test('sayfa aralıktan küçükse çökmez', () {
    expect(templateLines(PageTemplate.ruled, 100, 40, spacing: 50).horizontal, isEmpty);
    expect(templateLines(PageTemplate.grid, 30, 30, spacing: 50).isEmpty, isTrue);
  });
}
