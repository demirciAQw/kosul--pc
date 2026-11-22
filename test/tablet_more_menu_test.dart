import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/app_shell.dart';
import 'package:kocum/app/router.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/app/tablet_more_menu.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/question_bank/question_bank_providers.dart';

const _shellPaths = ['/', '/anlik', '/books', '/notebook', '/mock', '/insights'];

Widget _page(String t) => Scaffold(body: Center(child: Text('sayfa-$t')));

/// Menüdeki her rota için sahte sayfa; çerçeveli olanlar TabletFrame ile.
GoRouter _router() => GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (c, s, shell) => AppShell(shell: shell),
      branches: [
        for (final p in _shellPaths)
          StatefulShellBranch(
            routes: [GoRoute(path: p, builder: (c, s) => _page(p))],
          ),
      ],
    ),
    for (final p in tabletMenuRoutes.where((p) => !_shellPaths.contains(p)))
      GoRoute(
        path: p,
        builder: (c, s) => TabletFrame(
          selected: p == '/settings' ? RailItem.ayarlar : RailItem.daha,
          child: _page(p),
        ),
      ),
  ],
);

Future<void> _pump(WidgetTester t, GoRouter r, Size size) async {
  debugAndroidOverride = true;
  addTearDown(() => debugAndroidOverride = null);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [dueCountProvider.overrideWith((ref) => Stream.value(0))],
      child: MaterialApp.router(routerConfig: r),
    ),
  );
  await t.pump();
}

Future<void> _openMenu(WidgetTester t) async {
  await t.tap(find.byKey(const Key('rail-daha-menu')));
  await t.pumpAndSettle();
}

Future<void> _reveal(WidgetTester t, String id) async {
  await t.scrollUntilVisible(
    find.byKey(Key('rail-more-$id')),
    120,
    scrollable: find.descendant(
      of: find.byKey(const Key('rail-more-panel')),
      matching: find.byType(Scrollable),
    ),
  );
  await t.ensureVisible(find.byKey(Key('rail-more-$id')));
  await t.pumpAndSettle();
}

void main() {
  final entries = [for (final g in tabletMoreGroups) ...g.entries];

  group('Daha fazla menüsü', () {
    testWidgets('açılır; tüm gruplar ve öğeler listelenir', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      await _openMenu(t);
      expect(find.byKey(const Key('rail-more-panel')), findsOneWidget);
      expect(t.getSize(find.byKey(const Key('rail-more-panel'))).width, greaterThanOrEqualTo(320));
      for (final g in tabletMoreGroups) {
        await t.scrollUntilVisible(
          find.descendant(
            of: find.byKey(const Key('rail-more-panel')),
            matching: find.text(g.title),
          ).first,
          120,
          scrollable: find.descendant(
            of: find.byKey(const Key('rail-more-panel')),
            matching: find.byType(Scrollable),
          ),
        );
        for (final e in g.entries) {
          await _reveal(t, e.id);
          expect(
            find.descendant(
              of: find.byKey(Key('rail-more-${e.id}')),
              matching: find.text(e.label),
            ),
            findsOneWidget,
            reason: e.id,
          );
        }
      }
      expect(t.takeException(), isNull);
      // Dışına dokununca kapanır, ray bozulmaz.
      await t.tapAt(const Offset(1200, 400));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rail-more-panel')), findsNothing);
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
    });

    for (final e in entries.where((e) => e.route != null)) {
      testWidgets('${e.id} -> ${e.route}', (t) async {
        final r = _router();
        addTearDown(r.dispose);
        await _pump(t, r, const Size(1280, 800));
        await _openMenu(t);
        await _reveal(t, e.id);
        await t.tap(find.byKey(Key('rail-more-${e.id}')));
        await t.pumpAndSettle();
        expect(r.state.uri.path, e.route);
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
        expect(find.byKey(const Key('rail-more-panel')), findsNothing);
      });
    }

    testWidgets('çerçeveli sayfadan başka hedefe geçilir, yığın şişmez', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      await _openMenu(t);
      await _reveal(t, 'plan');
      await t.tap(find.byKey(const Key('rail-more-plan')));
      await t.pumpAndSettle();
      await _openMenu(t);
      await _reveal(t, 'sessions');
      await t.tap(find.byKey(const Key('rail-more-sessions')));
      await t.pumpAndSettle();
      expect(r.state.uri.path, '/sessions');
      // Tek geri: kabuk ana sayfaya (yığında /plan kalmadı).
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(r.state.uri.path, isNot('/plan'));
      expect(r.state.uri.path, isNot('/sessions'));
    });

    testWidgets('seçili hedef menüde ve rayda vurgulanır', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      r.go('/mock');
      await t.pumpAndSettle();
      await _openMenu(t);
      await _reveal(t, 'mock');
      final tile = t.widget<ListTile>(find.byKey(const Key('rail-more-mock')));
      expect(tile.selected, isTrue);
      await _reveal(t, 'tags');
      final other = t.widget<ListTile>(find.byKey(const Key('rail-more-tags')));
      expect(other.selected, isFalse);
      await t.tapAt(const Offset(1200, 400));
      await t.pumpAndSettle();
      // Ray: Daha fazla göstergesi seçili renkte.
      final cs = Theme.of(t.element(find.byKey(const Key('tablet-rail')))).colorScheme;
      Color? pill(String key) => t
          .widgetList<Container>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Container)))
          .map((c) => (c.decoration as BoxDecoration?)?.color)
          .whereType<Color>()
          .firstOrNull;
      expect(pill('rail-daha-menu'), cs.secondaryContainer);
      expect(pill('rail-notlar'), Colors.transparent);
    });

    testWidgets('çerçeveli menü sayfasında ray var, Ayarlar vurgulu', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      r.go('/settings');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      expect(find.text('sayfa-/settings'), findsOneWidget);
    });

    testWidgets('telefonda ray ve menü yok, alt çubuk korunur', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [dueCountProvider.overrideWith((ref) => Stream.value(0))],
          child: MaterialApp.router(routerConfig: r),
        ),
      );
      await t.pump();
      expect(find.byKey(const Key('rail-daha-menu')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      r.go('/plan');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
    });
  });

  group('ray yerleşimi', () {
    for (final size in const [Size(1280, 800), Size(800, 1280), Size(1280, 610)]) {
      testWidgets('taşma yok ${size.width.toInt()}x${size.height.toInt()}', (t) async {
        final r = _router();
        addTearDown(r.dispose);
        await _pump(t, r, size);
        expect(t.takeException(), isNull);
        expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 96);
        expect(find.byKey(const Key('rail-ayarlar')), findsOneWidget);
        // Etiketler sığar: "Soru defteri" tek satırda kesilmez.
        final label = find.descendant(
          of: find.byKey(const Key('rail-soruDefteri')),
          matching: find.text('Soru defteri'),
        );
        final tp = t.renderObject<RenderParagraph>(label);
        expect(tp.didExceedMaxLines, isFalse);
        expect(t.getSize(find.byKey(const Key('rail-soruDefteri'))).width, 88);
      });
    }

    testWidgets('kısa yükseklikte üst kısım kayar, Ayarlar sabit kalır', (t) async {
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      final r = _router();
      addTearDown(r.dispose);
      await t.pumpWidget(
        ProviderScope(
          child: MaterialApp.router(routerConfig: r),
        ),
      );
      // Doğrudan raya: 200 dp yükseklik.
      await t.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: 200,
                child: TabletRail(selected: null, due: 0),
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      final ayar = t.getRect(find.byKey(const Key('rail-ayarlar')));
      final scroll = t.getRect(find.byKey(const Key('rail-scroll')));
      expect(ayar.top, greaterThanOrEqualTo(scroll.bottom - 0.5));
      expect(ayar.bottom, lessThanOrEqualTo(200));
      await t.drag(find.byKey(const Key('rail-scroll')), const Offset(0, -200));
      await t.pump();
      expect(t.getRect(find.byKey(const Key('rail-ayarlar'))), ayar);
    });
  });

  group('envanter: rotalar menüde', () {
    // Menüye bilerek konmayanlar (parametreli/ekranlı akışlar).
    const exempt = {
      '/session/active': 'aktif oturum: tam ekran zorunlu akış',
      '/mock/karne': 'extra ister; menüde "Karne içe aktar" dosya seçtirerek açar',
    };

    test('routes.dart sabit rotalarının hepsi menüde (ya da gerekçeli muaf)', () {
      final src = File('lib/app/routes.dart').readAsStringSync();
      final consts = RegExp(r"static const \w+ = '([^']+)';")
          .allMatches(src)
          .map((m) => m.group(1)!)
          .toSet();
      expect(consts.length, greaterThan(20));
      final menu = tabletMenuRoutes;
      final missing = consts.where((p) => !menu.contains(p) && !exempt.containsKey(p)).toList();
      expect(
        missing,
        isEmpty,
        reason: 'Bu rotalar tablet "Daha fazla" menüsünde yok '
            '(lib/app/tablet_more_menu.dart): $missing',
      );
      // Menüde olmayan rota uydurulmamış.
      expect(menu.difference(consts), isEmpty);
    });

    test('kimlikler ve rotalar tekil, grup boş değil', () {
      final ids = entries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final g in tabletMoreGroups) {
        expect(g.entries, isNotEmpty, reason: g.title);
      }
    });
  });

  group('gerçek routerProvider', () {
    testWidgets('menüden açılan sayfada ray kalır', (t) async {
      late AppDatabase db;
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
      });
      addTearDown(() => t.runAsync(db.close));
      late GoRouter router;
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: Consumer(
            builder: (c, ref, _) {
              router = ref.watch(routerProvider);
              return MaterialApp.router(routerConfig: router);
            },
          ),
        ),
      );
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await t.pump();
      await _openMenu(t);
      await _reveal(t, 'sessions');
      await t.tap(find.byKey(const Key('rail-more-sessions')));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(router.state.uri.path, '/sessions');
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 20));
    });
  });
}
