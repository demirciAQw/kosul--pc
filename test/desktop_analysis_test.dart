import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/desktop/analysis/analysis_page.dart';

void main() {
  testWidgets('Analiz sayfası boş ve dolu veritabanında açılır; salt okunur (giriş düğmesi yok)', (tester) async {
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase(NativeDatabase.memory(), 'pc');
    final c = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
    ]);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(seconds: 1)); // Drift'in sıfır süreli kapanış zamanlayıcıları
      // Analiz akışları açıkken kapanış beklemesin (yalnızca test düzeni).
      await tester.runAsync(() => db.close().timeout(const Duration(seconds: 2), onTimeout: () {}));
    });
    await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const MaterialApp(home: Scaffold(body: DesktopAnalysisPage()))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.text('Analiz'), findsOneWidget);
    expect(find.text('Yalnızca okunur'), findsOneWidget);
    expect(find.text('En çok yanlış'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Birkaç yanlış soru ekle: analiz yeniden kurulur, hata yok.
    for (var i = 0; i < 3; i++) {
      await db.customStatement(
          "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at, reason) "
          "VALUES ('q$i', 'wrong', 'independent', 'x', 'TYT Matematik', 3, '', 1760000000, 'calculation')");
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Salt okunur: bu sayfada kaydet/ekle düğmeleri yok.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
