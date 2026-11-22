import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/features/ink/domain/hold_detector.dart';

void main() {
  test('varsayılanlar: 600 ms, 6 px', () {
    final d = HoldDetector();
    expect(d.holdMs, 600);
    expect(d.tolerance, 6);
  });

  test('hareketsiz kalınca süre dolunca basılı sayılır (sahte zaman)', () {
    final d = HoldDetector(holdMs: 600, tolerance: 6)..start(100, 100, 0);
    expect(d.isHeld(599), isFalse);
    expect(d.isHeld(600), isTrue);
  });

  test('titreme (eşik içi) süreyi sıfırlamaz', () {
    final d = HoldDetector()..start(100, 100, 0);
    expect(d.onPoint(103, 102, 200), isFalse);
    expect(d.onPoint(98, 101, 400), isFalse);
    expect(d.isHeld(600), isTrue);
  });

  test('eşiği aşan hareket çapayı kaydırır ve süreyi sıfırlar', () {
    final d = HoldDetector()..start(100, 100, 0);
    expect(d.onPoint(130, 100, 500), isTrue);
    expect(d.isHeld(700), isFalse);
    expect(d.isHeld(1100), isTrue);
    // Yeni çapaya göre ölçülür: 130'dan 5 px titreme sorun değil.
    expect(d.onPoint(135, 100, 800), isFalse);
  });

  test('ayarlanabilir süre ve eşik', () {
    final d = HoldDetector(holdMs: 200, tolerance: 20)..start(0, 0, 0);
    expect(d.onPoint(15, 0, 50), isFalse);
    expect(d.isHeld(200), isTrue);
    expect(d.onPoint(25, 0, 60), isTrue);
  });

  test('başlamadan ya da sıfırlanınca basılı değil', () {
    final d = HoldDetector();
    expect(d.isHeld(10000), isFalse);
    d.start(0, 0, 0);
    d.reset();
    expect(d.isHeld(10000), isFalse);
    expect(d.onPoint(5, 5, 100), isTrue); // çapa yoksa ilk nokta çapa olur
  });
}
