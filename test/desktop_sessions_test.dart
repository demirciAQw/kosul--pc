import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/sessions_page.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 's${_n++}';
}

void main() {
  late AppDatabase db;
  var now = DateTime(2026, 10, 20, 10, 0, 0);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    now = DateTime(2026, 10, 20, 10, 0, 0);
    db = AppDatabase(NativeDatabase.memory(), 'pc');
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      idGeneratorProvider.overrideWithValue(_Ids()),
      clockProvider.overrideWithValue(() => now),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.runAsync(db.close);
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: Scaffold(body: DesktopSessionsPage()))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('kitapsız oturum: başlat, pencerede sayaç işler, bitir, sonuçları gir, süreyi düzelt, sil', (tester) async {
    await pump(tester);
    expect(find.textContaining('Henüz oturum yok'), findsOneWidget);

    // Kitapsız kip, ders seç, BAŞLA.
    await tester.tap(find.text('Kitapsız'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-ders')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TYT Matematik').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-basla')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('suren-oturum')), findsOneWidget);
    final first = tester.widget<Text>(find.byKey(const ValueKey('sayac'))).data;

    // Süre damgadan hesaplanır: saat 25 dk ilerler, tik sayacı günceller.
    now = now.add(const Duration(minutes: 25));
    await tester.pump(const Duration(seconds: 2));
    final later = tester.widget<Text>(find.byKey(const ValueKey('sayac'))).data;
    expect(later, isNot(first));
    expect(later, contains('25'));

    // Bitir (onaylı): Konu çalışması soru istemez → sonuç penceresi çıkmaz.
    await tester.tap(find.byKey(const ValueKey('oturum-bitir')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oturum-bitir-onay')));
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    await tester.pumpAndSettle();
    expect(find.text('Sonuçlar'), findsNothing);
    final s = (await db.select(db.studySessions).get()).single;
    expect(s.status, 'completed');
    expect(find.byKey(ValueKey('gecmis:${s.id}')), findsOneWidget);

    // Süreyi 40 dakikaya düzelt.
    await tester.tap(find.byKey(ValueKey('sure:${s.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sure-dk')), '40');
    await tester.tap(find.byKey(const ValueKey('sure-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();
    final edited = (await db.select(db.studySessions).get()).single;
    expect(edited.endedAt!.difference(edited.startedAt).inMinutes, 40);

    // Sil (onaylı).
    await tester.tap(find.byKey(ValueKey('sil:${s.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oturum-sil-onay')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(await db.select(db.studySessions).get(), isEmpty);
  });

  testWidgets('soru çözümü oturumu bitince sonuç penceresi açılır; D/Y/B kaydolur; iptal süre kaydetmez', (tester) async {
    await pump(tester);
    // Soru çözümü etkinliğiyle kitapsız oturum.
    await tester.tap(find.text('Kitapsız'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-ders')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TYT Fizik').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konu çalışması'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Soru çözümü').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-basla')));
    await settle(tester);
    await tester.pumpAndSettle();

    now = now.add(const Duration(minutes: 30));
    await tester.tap(find.byKey(const ValueKey('oturum-bitir')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oturum-bitir-onay')));
    for (var i = 0; i < 4; i++) {
      await settle(tester);
    }
    await tester.pumpAndSettle();
    expect(find.text('Sonuçlar'), findsOneWidget);
    final item = (await db.select(db.sessionItems).get()).single;
    await tester.enterText(find.byKey(ValueKey('d:${item.id}')), '14');
    await tester.enterText(find.byKey(ValueKey('y:${item.id}')), '4');
    await tester.enterText(find.byKey(ValueKey('b:${item.id}')), '2');
    await tester.tap(find.byKey(const ValueKey('sonuc-kaydet')));
    await settle(tester);
    await tester.pumpAndSettle();
    final saved = (await db.select(db.sessionItems).get()).single;
    expect((saved.correct, saved.wrong, saved.blank), (14, 4, 2));

    // Yeni oturum başlat ve iptal et: kayıt kalmaz.
    await tester.tap(find.text('Kitapsız'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-ders')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TYT Kimya').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('serbest-basla')));
    await settle(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oturum-iptal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oturum-iptal-onay')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect((await db.select(db.studySessions).get()).length, 1); // yalnızca bitmiş olan
    expect(find.byKey(const ValueKey('suren-oturum')), findsNothing);
  });
}
