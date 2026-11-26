import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/pen_profiles.dart';

void main() {
  test('her tür için kalınlık baskıyla azalmaz, uçlarda sınırlı', () {
    for (final prof in penProfiles.values) {
      for (final h in [0.0, 0.3, 0.5, 1.0]) {
        var prev = -1.0;
        for (var i = 0; i <= 20; i++) {
          final w = prof.widthAt(4, i / 20, hardness: h);
          expect(w, greaterThanOrEqualTo(prev));
          prev = w;
        }
        expect(prof.widthAt(4, 0, hardness: h), closeTo(4 * prof.minFactor, 1e-9));
        expect(prof.widthAt(4, 1, hardness: h), closeTo(4 * prof.maxFactor, 1e-9));
        // sınır dışı baskı kırpılır
        expect(prof.widthAt(4, -1, hardness: h), prof.widthAt(4, 0, hardness: h));
        expect(prof.widthAt(4, 3, hardness: h), prof.widthAt(4, 1, hardness: h));
      }
    }
  });

  test('sertlik: yumuşak hafif baskıda daha kalın', () {
    final f = penProfiles[PenKind.fountain]!;
    expect(f.widthAt(4, 0.4, hardness: 0), greaterThan(f.widthAt(4, 0.4, hardness: 1)));
  });

  test('fosforlu: çarpma, saydam, baskıdan bağımsız', () {
    final h = penProfiles[PenKind.highlighter]!;
    expect(h.multiply, isTrue);
    expect(h.opacity, lessThan(0.5));
    expect(h.widthAt(10, 0.1), h.widthAt(10, 0.9));
    expect(penProfiles[PenKind.ballpoint]!.multiply, isFalse);
  });

  test('palet ve seviyeler', () {
    expect(penPalette.length, 10);
    expect(penPalette.toSet().length, 10);
    expect(penPalette.every((c) => c >> 24 == 0xFF), isTrue);
    expect(penWidthLevels, orderedEquals([...penWidthLevels]..sort()));
    expect(nearestWidthLevel(4.4, penWidthLevels), 3);
    expect(penProfiles.length, PenKind.values.length);
  });
}
