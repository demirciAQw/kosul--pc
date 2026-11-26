import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/desktop/entry/optic_entry.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';

void main() {
  test('cevap anahtarı: yalnızca A–E, boşluk ve diğer harfler atılır, küçük harf kabul', () {
    expect(parseAnswerKey('ab cd\nE xyz 12 a'), ['A', 'B', 'C', 'D', 'E', 'A']);
    expect(parseAnswerKey(''), isEmpty);
  });

  group('şık kipi (anahtarlı)', () {
    OpticEntry entry() => OpticEntry(total: 5, answerKey: parseAnswerKey('ABCDE'));

    test('anahtarla aynı şık doğru, farklısı yanlış; otomatik sonraki soruya geçer', () {
      final e = entry();
      expect(e.mode, EntryMode.choice);
      e.press('a'); // 1: doğru
      e.press('C'); // 2: anahtar B → yanlış, işaretlenen C
      e.press('c'); // 3: doğru
      expect(e.cursor, 4);
      expect(e.marks, {2: QuestionStatus.wrong});
      expect(e.given, {2: 'C'});
      expect((e.correct, e.wrong, e.blank), (4, 1, 0));
      expect(e.net, 3.75); // 4 doğru − 1/4
    });

    test('boşluk boş, Enter doğru sayar; Backspace geri gidip siler', () {
      final e = entry();
      e.press(' ');
      e.press('E');
      expect(e.marks, {1: QuestionStatus.blank, 2: QuestionStatus.wrong});
      e.press('Backspace'); // 2'ye döndü, işareti silindi
      expect(e.cursor, 2);
      expect(e.marks, {1: QuestionStatus.blank});
      e.press('Enter'); // 2: doğru
      expect(e.cursor, 3);
      e.press('Backspace');
      e.press('Backspace');
      expect(e.cursor, 1);
      expect(e.marks, isEmpty);
    });

    test('son soruda kalır; sınırda geri tuşu 1\'in altına inmez', () {
      final e = OpticEntry(total: 2, answerKey: ['A', 'B']);
      e.press('A');
      e.press('A'); // 2: yanlış
      expect(e.cursor, 2);
      e.press('A'); // yine 2'de, üzerine yazar
      expect(e.marks, {2: QuestionStatus.wrong});
      final f = OpticEntry(total: 3, answerKey: ['A']);
      f.press('Backspace');
      expect(f.cursor, 1);
    });

    test('anahtarı olmayan soruda şık tuşu tanınmaz', () {
      final e = OpticEntry(total: 3, answerKey: ['A']);
      e.press('A');
      expect(e.press('B'), isFalse); // 2. sorunun anahtarı yok
      expect(e.cursor, 2);
    });
  });

  group('durum kipi (anahtarsız)', () {
    test('D doğru, Y yanlış, B boş; şık harfleri kip gereği durum', () {
      final e = OpticEntry(total: 4);
      expect(e.mode, EntryMode.status);
      e.press('Y');
      e.press('b');
      e.press('d');
      e.press('y');
      expect(e.marks, {1: QuestionStatus.wrong, 2: QuestionStatus.blank, 4: QuestionStatus.wrong});
      expect(e.given, isEmpty);
      expect(e.press('A'), isFalse);
      expect(e.press('Z'), isFalse);
    });

    test('önceki işaretlerle açılır; aralık dışı ve doğru olanlar alınmaz', () {
      final e = OpticEntry(total: 3, initial: {1: QuestionStatus.wrong, 3: QuestionStatus.correct, 9: QuestionStatus.blank});
      expect(e.marks, {1: QuestionStatus.wrong});
    });
  });

  test('anahtar sonradan girilince şık kipine geçer; kip değiştirilebilir', () {
    final e = OpticEntry(total: 3);
    e.toggleMode(); // anahtar yok: geçilemez
    expect(e.mode, EntryMode.status);
    e.setKey(['A', 'B', 'C']);
    expect(e.mode, EntryMode.choice);
    e.toggleMode();
    expect(e.mode, EntryMode.status);
    e.toggleMode();
    expect(e.mode, EntryMode.choice);
    e.setKey([]);
    expect(e.mode, EntryMode.status);
    e.select(99);
    expect(e.cursor, 3);
    e.move(-10);
    expect(e.cursor, 1);
  });
}
