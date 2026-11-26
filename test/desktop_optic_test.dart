import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/optic_page.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/library/library_providers.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'o${_n++}';
}

void main() {
  late AppDatabase db;
  late ProviderContainer c;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      idGeneratorProvider.overrideWithValue(_Ids()),
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(db.close);
    });
    await tester.runAsync(() => c.read(libraryRepositoryProvider).save(Book(
          id: 'kitap',
          title: '345 Matematik',
          examType: 'TYT',
          subject: 'Matematik',
          pageCount: 100,
          avgQuestionsPerPage: 0.5,
          createdAt: DateTime(2026),
          roots: const [
            ContentNode(id: 'u', level: NodeLevel.unit, title: 'Türev', children: [
              ContentNode(id: 't1', level: NodeLevel.topic, title: 'Test 1', questionCount: 6),
            ]),
          ],
        )));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: Scaffold(body: DesktopOpticPage())),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('Kitaplar\'dan gelen test açılır; D/Y/B tuşlarıyla hızlı giriş, otomatik ilerleme, kayıt', (tester) async {
    await pump(tester);
    expect(find.text('Bir kitap ve test seç.'), findsOneWidget);
    c.read(opticTargetProvider.notifier).set('t1');
    await settle(tester);
    expect(find.byKey(const ValueKey('hucre:6')), findsOneWidget);
    expect(c.read(opticTargetProvider), isNull); // hedef bir kez kullanıldı

    await tester.sendKeyEvent(LogicalKeyboardKey.keyY); // 1 yanlış
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD); // 2 doğru
    await tester.sendKeyEvent(LogicalKeyboardKey.space); // 3 boş
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB); // 4 boş
    await tester.pump();
    expect(find.text('Doğru 3   Yanlış 1   Boş 2   Net 2.75'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace); // 4'e dön, sil
    await tester.pump();
    expect(find.text('Doğru 4   Yanlış 1   Boş 1   Net 3.75'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    await settle(tester);

    final cards = await db.select(db.questionCards).get();
    expect({for (final k in cards) k.questionNo: k.status}, {1: 'wrong', 3: 'blank'});
    expect(cards.every((k) => k.contentNodeId == 't1' && k.bookId == 'kitap' && k.origin == 'book'), isTrue);
    final res = (await db.select(db.testResults).get()).single;
    expect((res.contentNodeId, res.correct, res.wrong, res.blank, res.total), ('t1', 4, 1, 1, 6));
    expect(find.textContaining('2 yeni soru deftere eklendi'), findsOneWidget);
  });

  testWidgets('cevap anahtarıyla A–E: durum kendiliğinden, cevaplar karta yazılır; önceki işaretler yüklenir', (tester) async {
    await pump(tester);
    c.read(opticTargetProvider.notifier).set('t1');
    await settle(tester);

    await tester.enterText(find.byKey(const ValueKey('optik-anahtar')), 'ABCDEA');
    await tester.pump();
    // Izgaraya dön ve şıkları gir: 1 doğru(A), 2 yanlış(C), 3 boş.
    await tester.tap(find.byKey(const ValueKey('hucre:1')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('Doğru 4   Yanlış 1   Boş 1   Net 3.75'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('optik-kaydet')));
    await settle(tester);
    await settle(tester);

    final byNo = {for (final k in await db.select(db.questionCards).get()) k.questionNo: k};
    expect((byNo[2]!.status, byNo[2]!.correctAnswer, byNo[2]!.givenAnswer), ('wrong', 'B', 'C'));
    expect((byNo[3]!.status, byNo[3]!.correctAnswer, byNo[3]!.givenAnswer), ('blank', 'C', null));

    // Testi yeniden aç: önceki işaretler gelir.
    c.read(opticTargetProvider.notifier).set(null);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: Scaffold(body: DesktopOpticPage()))));
    c.read(opticTargetProvider.notifier).set('t1');
    await settle(tester);
    expect(find.text('Doğru 4   Yanlış 1   Boş 1   Net 3.75'), findsOneWidget);
  });
}
