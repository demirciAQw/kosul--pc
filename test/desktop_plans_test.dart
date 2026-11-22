import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/plans_page.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'p${_n++}';
}

void main() {
  late AppDatabase db;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 950);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      idGeneratorProvider.overrideWithValue(_Ids()),
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: Scaffold(body: DesktopPlansPage()))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 2; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('plan oluştur (haftalık hazır aralık, görevler satır satır); görev ekle, işaretle, yeniden adlandır, sil', (tester) async {
    await pump(tester);
    expect(find.textContaining('Henüz plan yok'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plan-olustur')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plan-yeni-ad')), '');
    await tester.tap(find.byKey(const ValueKey('plan-olustur-onay')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('Plana bir ad ver.'), findsOneWidget); // doğrulama (SnackBar)
    expect(await db.select(db.studyPlans).get(), isEmpty);

    await tester.tap(find.byKey(const ValueKey('plan-olustur')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('plan-yeni-ad')), '26 Ekim haftası');
    await tester.enterText(find.byKey(const ValueKey('plan-gorevler')), 'Türev tekrar\n\nFizik testi\n');
    await tester.tap(find.byKey(const ValueKey('plan-olustur-onay')));
    await settle(tester);
    final plan = (await db.select(db.studyPlans).get()).single;
    expect(plan.title, '26 Ekim haftası');
    expect(plan.endsOn.difference(plan.startsOn).inDays, 6); // haftalık: 7 gün
    final tasks = await db.select(db.planTasks).get();
    expect(tasks.map((t) => t.title), ['Türev tekrar', 'Fizik testi']);

    // Görev ekle (Enter), işaretle, yeniden adlandır.
    await tester.enterText(find.byKey(const ValueKey('gorev-yeni')), 'Deneme çöz');
    await tester.tap(find.byKey(const ValueKey('gorev-ekle')));
    await settle(tester);
    expect((await db.select(db.planTasks).get()).length, 3);

    await tester.tap(find.byKey(ValueKey('gorev:${tasks.first.id}')));
    await settle(tester);
    expect((await db.select(db.planTasks).get()).firstWhere((t) => t.id == tasks.first.id).isDone, isTrue);
    expect(find.textContaining('1/3 görev'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('gorev-ad:${tasks.last.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('gorev-yeni-ad')), 'Fizik testi 2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect((await db.select(db.planTasks).get()).any((t) => t.title == 'Fizik testi 2'), isTrue);

    // Görev sil (onaylı).
    await tester.tap(find.byKey(ValueKey('gorev-sil:${tasks.first.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gorev-sil-onay')));
    await settle(tester);
    expect((await db.select(db.planTasks).get()).length, 2);

    // Plan tamamlandı işareti ve plan silme.
    await tester.tap(find.byKey(const ValueKey('plan-tamamla')));
    await settle(tester);
    expect((await db.select(db.studyPlans).get()).single.completedAt, isNotNull);
    await tester.tap(find.byKey(const ValueKey('plan-sil')));
    await tester.pumpAndSettle();
    expect(find.text('Plan silinsin mi?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plan-sil-onay')));
    await settle(tester);
    expect(await db.select(db.studyPlans).get(), isEmpty);
  });

  testWidgets('yapay zekâ programı: önizleme, geçersiz JSON hatası, plan olarak kaydet', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('program-ice-aktar')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('program-metin')), 'merhaba');
    await tester.tap(find.byKey(const ValueKey('program-denetle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('JSON bulunamadı'), findsOneWidget);

    const json = '''Şöyle bir program:
```json
{"format":"kocum.plan","version":1,"title":"Hafta 1","startsOn":"2026-10-26","endsOn":"2026-11-01",
 "tasks":[{"date":"2026-10-26","title":"Üstel fonksiyonlar tekrar","subject":"AYT Matematik","questions":20},
          {"date":"2026-10-27","title":"Fizik tekrar","minutes":40}]}
```''';
    await tester.enterText(find.byKey(const ValueKey('program-metin')), json);
    await tester.tap(find.byKey(const ValueKey('program-denetle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Hafta 1: 2 görev'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('program-kaydet')));
    await settle(tester);
    expect((await db.select(db.studyPlans).get()).single.title, 'Hafta 1');
    expect((await db.select(db.planTasks).get()).length, 2);
  });
}
