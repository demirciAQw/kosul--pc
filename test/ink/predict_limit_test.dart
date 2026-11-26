import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/predict_limit.dart';

void main() {
  PredictLimiter moving(double speed) {
    final l = PredictLimiter();
    for (var i = 0; i < 5; i++) {
      l.record(i * speed * 8, 0, i * 8.0); // 8 ms aralık
    }
    return l;
  }

  List<PredictPoint> ahead(PredictLimiter l, double from, int n) => [
    for (var i = 1; i <= n; i++) PredictPoint(from + i * 10.0, 0, 32.0 + i * 4),
  ];

  test('az veri ya da durmuş kalem: tahmin yok', () {
    final l = PredictLimiter();
    expect(l.isStill, isTrue);
    l.record(0, 0, 0);
    expect(l.clip(ahead(l, 0, 3)), isEmpty);
    // Titreşim: +-0,3 dp, 3 olay -> durmuş.
    for (var i = 1; i <= 4; i++) {
      l.record(i.isEven ? 0.3 : -0.3, 0, i * 8.0);
    }
    expect(l.isStill, isTrue);
    expect(l.maxLead, 0);
    expect(l.clip(ahead(l, 0, 3)), isEmpty);
  });

  test('hız eşiğinin altı tahminsiz, üstü tahminli', () {
    // 0,05 dp/ms < 0,08: yavaş; hareket 0,4 dp/olay ama durma sayacı da tetiklenir.
    expect(moving(0.05).isStill, isTrue);
    expect(moving(0.05).clip(ahead(moving(0.05), 32 * 0.05, 3)), isEmpty);
    final fast = moving(0.5);
    expect(fast.isStill, isFalse);
    expect(fast.speed, closeTo(0.5, 1e-9));
  });

  test('tahmin yolu hiz x 16 ms ile sinirlanir ve ara degerlenir', () {
    final l = moving(0.5); // son nokta x=16
    expect(l.maxLead, closeTo(8.0, 1e-9)); // 0,5 x 16 x 1
    final out = l.clip([
      const PredictPoint(20, 0, 36),
      const PredictPoint(40, 0, 40),
    ]);
    // 4 dp'lik ilk parça tam, ikincisi 4 dp'ye kırpılır.
    expect(out.length, 2);
    expect(out.first.x, 20);
    expect(out.last.x, closeTo(24, 1e-9));
    expect(out.last.t, closeTo(36 + 4 * 4 / 20, 1e-9));
    var d = 0.0;
    var px = 16.0;
    for (final p in out) {
      d += (p.x - px).abs();
      px = p.x;
    }
    expect(d, lessThanOrEqualTo(l.maxLead + 1e-9));
  });

  test('cok hizli kalemde mutlak ust sinir', () {
    final l = moving(10); // 10 dp/ms -> 160 dp, sınır 24
    expect(l.maxLead, PredictLimits.maxLeadDp);
    final out = l.clip(ahead(l, 320, 20));
    expect(out.last.x - 320, closeTo(PredictLimits.maxLeadDp, 1e-9));
  });

  test('kalem durunca tahmin kesilir; yeniden hareketle geri gelir', () {
    final l = moving(0.5);
    expect(l.isStill, isFalse);
    for (var i = 0; i < PredictLimits.stillCount; i++) {
      l.record(16.2, 0.1, 40.0 + i * 8);
    }
    expect(l.isStill, isTrue);
    expect(l.clip(ahead(l, 16, 3)), isEmpty);
    l.reset();
    expect(l.isStill, isTrue);
  });

  test('sabitler makul', () {
    expect(PredictLimits.stillSpeed, inInclusiveRange(0.03, 0.15));
    expect(PredictLimits.horizonMs, lessThanOrEqualTo(24));
    expect(PredictLimits.leadScale, lessThanOrEqualTo(1.0));
  });
}
