import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/stroke_lod.dart';

void main() {
  test('visibleStrokes yalnız kesişenleri verir', () {
    final b = [const LodRect(0, 0, 10, 10), const LodRect(100, 100, 110, 110)];
    expect(visibleStrokes(b, const LodRect(5, 5, 50, 50)), [0]);
  });

  test('pointBudget en yeniyi tutar, eskiyi atar', () {
    expect(pointBudget([100, 100, 100], 250), [false, true, true]);
    expect(pointBudget([500], 10), [true]);
  });

  test('simplifyPoints doğru üstündeki noktaları atar, köşeyi tutar', () {
    final pts = [(0.0, 0.0), (1.0, 0.0), (2.0, 0.0), (2.0, 2.0)];
    final r = simplifyPoints<(double, double)>(pts, 0.1, (p) => p.$1, (p) => p.$2);
    expect(r, [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0)]);
  });
}
