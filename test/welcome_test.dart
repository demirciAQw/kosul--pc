import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/app_shell.dart';
import 'package:kocum/app/widgets/home_logo_button.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/welcome/welcome_providers.dart';
import 'package:kocum/features/welcome/welcome_screen.dart';

Future<(AppDatabase, ProviderContainer)> _setup(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  final container = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(db.close);
  });
  return (db, container);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('ilk açılışta hoş geldin ekranı; Geç ile ana uygulamaya, bir daha çıkmaz', (tester) async {
    final (db, c) = await _setup(tester);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: WelcomeGate(child: Text('ANA UYGULAMA'))),
    ));
    await _settle(tester);
    expect(find.text('Koçum\'a hoş geldin'), findsOneWidget);
    expect(find.text('ANA UYGULAMA'), findsNothing);

    await tester.tap(find.byKey(const Key('welcome-skip')));
    await _settle(tester);
    expect(find.text('ANA UYGULAMA'), findsOneWidget);
    final row = await tester.runAsync(
        () => (db.select(db.appMeta)..where((m) => m.metaKey.equals('app.welcome_seen'))).getSingle());
    expect(row!.metaValue, '1');
  });

  testWidgets('İleri ile sayfalar gezilir, son sayfada Başla görülür', (tester) async {
    final (_, c) = await _setup(tester);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: WelcomeGate(child: Text('ANA UYGULAMA'))),
    ));
    await _settle(tester);
    for (var i = 0; i < 3; i++) {
      expect(find.text('İleri'), findsOneWidget);
      await tester.tap(find.byKey(const Key('welcome-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Başla'), findsOneWidget);
    expect(find.text('Geç'), findsNothing);
    await tester.tap(find.byKey(const Key('welcome-next')));
    await _settle(tester);
    expect(find.text('ANA UYGULAMA'), findsOneWidget);
  });

  testWidgets('görüldüyse hoş geldin ekranı çıkmaz; ayardan sıfırlanınca yine çıkar', (tester) async {
    final (db, c) = await _setup(tester);
    await tester.runAsync(() => WelcomeRepository(db).set(true));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(home: WelcomeGate(child: Text('ANA UYGULAMA'))),
    ));
    await _settle(tester);
    expect(find.text('ANA UYGULAMA'), findsOneWidget);

    await tester.runAsync(() => c.read(welcomeSeenProvider.notifier).reset());
    await _settle(tester);
    expect(find.text('Koçum\'a hoş geldin'), findsOneWidget);
  });

  testWidgets('alt çubukta 5 sekme var (Bugün ve Araçlar yok); logo ana ekrana döner', (tester) async {
    final (_, c) = await _setup(tester);
    Widget page(String name) => Scaffold(
          appBar: AppBar(leading: const HomeLogoButton(), leadingWidth: HomeLogoButton.width, title: Text(name)),
          body: Text('sayfa-$name'),
        );
    final router = GoRouter(routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(shell: shell),
        branches: [
          for (final p in ['/', '/anlik', '/books', '/notebook', '/mock', '/insights'])
            StatefulShellBranch(routes: [GoRoute(path: p, builder: (_, _) => page(p))]),
        ],
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _settle(tester);

    // Ana ekran: çubuk görünür, seçili sekme yok.
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    for (final l in ['Anlık', 'Kitaplar', 'Defter', 'Deneme', 'Analiz']) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.text('Bugün'), findsNothing);
    expect(find.text('Araçlar'), findsNothing);
    expect(find.text('sayfa-/'), findsOneWidget);

    // Analiz sekmesi (çubuktaki 5.) → dal 5.
    await tester.tap(find.text('Analiz'));
    await _settle(tester);
    expect(find.text('sayfa-/insights'), findsOneWidget);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 4);

    // Logo → ana ekran.
    await tester.tap(find.byKey(const Key('home-logo')));
    await _settle(tester);
    expect(find.text('sayfa-/'), findsOneWidget);
  });
}
