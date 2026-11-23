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
import 'package:kocum/app/tablet_menu.dart';
import 'package:kocum/app/tablet_menu_prefs.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/question_bank/question_bank_providers.dart';

const _shellPaths = [
  '/',
  '/anlik',
  '/books',
  '/notebook',
  '/mock',
  '/insights',
];

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
          selected: p == '/settings' ? RailItem.ayarlar : RailItem.diger,
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

Future<void> _reveal(
  WidgetTester t,
  String id, {
  String prefix = 'menu-',
}) async {
  final list = find.byKey(const Key('menu-scroll'));
  await t.drag(list, const Offset(0, 8000)); // en başa
  await t.pump();
  await t.scrollUntilVisible(
    find.byKey(Key('$prefix$id')),
    120,
    scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
  );
  await t.pumpAndSettle();
}

Color? _fill(WidgetTester t, String id) => t
    .widgetList<Material>(
      find.descendant(
        of: find.byKey(Key('menu-$id')),
        matching: find.byType(Material),
      ),
    )
    .map((m) => m.color)
    .whereType<Color>()
    .firstOrNull;

class _Narrow extends TabletMenuNarrow {
  @override
  bool build() => true;
}

void main() {
  final entries = [for (final g in tabletMenuGroups) ...g.entries];

  group('sol menü (genişletilmiş)', () {
    testWidgets('"Daha fazla" yok; tüm gruplar ve öğeler doğrudan listelenir', (
      t,
    ) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      expect(find.text('Daha fazla'), findsNothing);
      expect(find.byKey(const Key('rail-daha-menu')), findsNothing);
      expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 232);
      expect(find.text('Koçum'), findsOneWidget);
      for (final g in tabletMenuGroups) {
        await _reveal(t, g.title, prefix: 'menu-group-');
        expect(
          find.byKey(Key('menu-group-${g.title}')),
          findsOneWidget,
          reason: g.title,
        );
        for (final e in g.entries) {
          await _reveal(t, e.id);
          expect(
            find.descendant(
              of: find.byKey(Key('menu-${e.id}')),
              matching: find.text(e.label),
            ),
            findsOneWidget,
            reason: e.id,
          );
        }
      }
      expect(find.text('Daha fazla'), findsNothing);
      expect(t.takeException(), isNull);
      expect(find.byKey(const Key('menu-settings')), findsOneWidget);
    });

    test('grup başlıkları sırayla ve beklenen adlarla', () {
      expect(
        [for (final g in tabletMenuGroups) g.title],
        [
          'Çalışma',
          'Sorular',
          'Kitaplar ve denemeler',
          'Notlar',
          'Analiz',
          'Tablet',
          'Araçlar',
        ],
      );
    });

    for (final e in [
      ...entries,
      tabletMenuSettings,
    ].where((e) => e.route != null)) {
      testWidgets('${e.id} -> ${e.route}', (t) async {
        final r = _router();
        addTearDown(r.dispose);
        await _pump(t, r, const Size(1280, 800));
        if (e.id != 'settings') await _reveal(t, e.id);
        await t.tap(find.byKey(Key('menu-${e.id}')));
        await t.pumpAndSettle();
        expect(r.state.uri.path, e.route);
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      });
    }

    testWidgets('çerçeveli sayfadan başka hedefe geçilir, yığın şişmez', (
      t,
    ) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      await _reveal(t, 'plan');
      await t.tap(find.byKey(const Key('menu-plan')));
      await t.pumpAndSettle();
      await _reveal(t, 'sessions');
      await t.tap(find.byKey(const Key('menu-sessions')));
      await t.pumpAndSettle();
      expect(r.state.uri.path, '/sessions');
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(r.state.uri.path, isNot('/plan'));
      expect(r.state.uri.path, isNot('/sessions'));
    });

    testWidgets('seçili hedef vurgulanır, diğerleri değil', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      r.go('/mock');
      await t.pumpAndSettle();
      final cs = Theme.of(t.element(find.byKey(const Key('tablet-rail'))))
          .colorScheme;
      await _reveal(t, 'mock');
      expect(_fill(t, 'mock'), cs.secondaryContainer);
      await _reveal(t, 'tags');
      expect(_fill(t, 'tags'), Colors.transparent);
      r.go('/settings');
      await t.pumpAndSettle();
      expect(_fill(t, 'settings'), cs.secondaryContainer);
    });

    testWidgets('telefonda menü/ray yok, alt çubuk korunur', (t) async {
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
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
      expect(find.byKey(const Key('menu-collapse')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
      r.go('/plan');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
    });
  });

  group('daralt / genişlet', () {
    testWidgets('daralt dar ikon rayı verir; genişlet geri getirir', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, r, const Size(1280, 800));
      await t.tap(find.byKey(const Key('menu-collapse')));
      await t.pumpAndSettle();
      expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 96);
      for (final id in tabletRailIds) {
        expect(find.byKey(Key('rail-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const Key('rail-settings')), findsOneWidget);
      expect(find.byKey(const Key('menu-new-session')), findsNothing);
      expect(find.text('Daha fazla'), findsNothing);
      await t.tap(find.byKey(const Key('rail-mock')));
      await t.pumpAndSettle();
      expect(r.state.uri.path, '/mock');
      await t.tap(find.byKey(const Key('menu-expand')));
      await t.pumpAndSettle();
      expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 232);
      expect(find.byKey(const Key('menu-collapse')), findsOneWidget);
    });

    testWidgets('tercih app_meta tablet.menu_dar altında kalıcı', (t) async {
      late AppDatabase db;
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
      });
      addTearDown(() => t.runAsync(db.close));
      Future<void> app() async {
        final r = _router();
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              dueCountProvider.overrideWith((ref) => Stream.value(0)),
            ],
            child: MaterialApp.router(routerConfig: r),
          ),
        );
        await t.runAsync(
          () => Future.delayed(const Duration(milliseconds: 80)),
        );
        await t.pump();
      }

      Future<String?> saved() async {
        final row = await t.runAsync(
          () =>
              (db.select(db.appMeta)
                    ..where((m) => m.metaKey.equals(tabletMenuNarrowKey)))
                  .getSingleOrNull(),
        );
        return row?.metaValue;
      }

      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await app();
      expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 232);
      await t.tap(find.byKey(const Key('menu-collapse')));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 80)));
      await t.pump();
      expect(await saved(), 'true');
      await t.pumpWidget(const SizedBox());
      await app();
      expect(t.getSize(find.byKey(const Key('tablet-rail'))).width, 96);
      await t.tap(find.byKey(const Key('menu-expand')));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 80)));
      await t.pump();
      expect(await saved(), 'false');
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
      await t.pump(const Duration(milliseconds: 20));
    });
  });

  group('yerleşim', () {
    for (final size in const [
      Size(1250, 2000),
      Size(2000, 1250),
      Size(1280, 800),
      Size(800, 1280),
      Size(1280, 610),
      Size(610, 800),
    ]) {
      for (final narrow in [false, true]) {
        testWidgets(
          'taşma yok ${size.width.toInt()}x${size.height.toInt()} ${narrow ? 'dar' : 'geniş'}',
          (t) async {
            final r = _router();
            addTearDown(r.dispose);
            await _pump(t, r, size);
            if (narrow) {
              await t.tap(find.byKey(const Key('menu-collapse')));
              await t.pumpAndSettle();
            }
            expect(t.takeException(), isNull);
            expect(
              t.getSize(find.byKey(const Key('tablet-rail'))).width,
              narrow ? 96 : 232,
            );
            final settings = find.byKey(
              Key(narrow ? 'rail-settings' : 'menu-settings'),
            );
            expect(settings, findsOneWidget);
            expect(t.getRect(settings).bottom, lessThanOrEqualTo(size.height));
            if (narrow) {
              final label = find.descendant(
                of: find.byKey(const Key('rail-notebook')),
                matching: find.text('Soru defteri'),
              );
              expect(
                t.renderObject<RenderParagraph>(label).didExceedMaxLines,
                isFalse,
              );
            } else {
              // Her etiket tek satır ve kesilmeden sığar (en uzunu hariç elipsle).
              await _reveal(t, 'home');
              final label = find.descendant(
                of: find.byKey(const Key('menu-home')),
                matching: find.text('Bugün'),
              );
              expect(
                t.renderObject<RenderParagraph>(label).didExceedMaxLines,
                isFalse,
              );
            }
          },
        );
      }
    }

    for (final narrow in [false, true]) {
      testWidgets(
        'kısa yükseklikte liste kayar, Ayarlar sabit (${narrow ? 'dar' : 'geniş'})',
        (t) async {
          debugAndroidOverride = true;
          addTearDown(() => debugAndroidOverride = null);
          await t.pumpWidget(
            ProviderScope(
              overrides: [
                if (narrow)
                  tabletMenuNarrowProvider.overrideWith(() => _Narrow()),
              ],
              child: const MaterialApp(
                home: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    height: 260,
                    child: TabletRail(selected: null, due: 0),
                  ),
                ),
              ),
            ),
          );
          expect(t.takeException(), isNull);
          final ayar = t.getRect(
            find.byKey(Key(narrow ? 'rail-settings' : 'menu-settings')),
          );
          final scroll = t.getRect(
            find.byKey(Key(narrow ? 'rail-scroll' : 'menu-scroll')),
          );
          expect(ayar.top, greaterThanOrEqualTo(scroll.bottom - 0.5));
          expect(ayar.bottom, lessThanOrEqualTo(260));
          await t.drag(
            find.byKey(Key(narrow ? 'rail-scroll' : 'menu-scroll')),
            const Offset(0, -200),
          );
          await t.pump();
          expect(
            t.getRect(
              find.byKey(Key(narrow ? 'rail-settings' : 'menu-settings')),
            ),
            ayar,
          );
        },
      );
    }

    testWidgets('sistem alt çubuğu payı korunur (SafeArea)', (t) async {
      debugAndroidOverride = true;
      addTearDown(() => debugAndroidOverride = null);
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            builder: (c, w) => MediaQuery(
              data: MediaQuery.of(c).copyWith(
                padding: const EdgeInsets.only(bottom: 96),
                viewPadding: const EdgeInsets.only(bottom: 96),
              ),
              child: w!,
            ),
            home: const Scaffold(
              body: Row(children: [TabletRail(selected: null, due: 0)]),
            ),
          ),
        ),
      );
      expect(
        t.getRect(find.byKey(const Key('menu-settings'))).bottom,
        lessThanOrEqualTo(800 - 96 + 0.5),
      );
    });
  });

  group('envanter: rotalar menüde', () {
    // Menüye bilerek konmayanlar (parametreli/ekranlı akışlar).
    const exempt = {
      '/session/active': 'aktif oturum: tam ekran zorunlu akış',
      '/mock/karne':
          'extra ister; menüde "Karne içe aktar" dosya seçtirerek açar',
      '/saglik': 'Ayarlar > Sağlık verisi kartından açılır (yalnız Android)',
      '/saglik/huawei': 'Ayarlar > Sağlık verisi kartından açılır (yalnız Android)',
    };

    test(
      'routes.dart sabit rotalarının hepsi menüde (ya da gerekçeli muaf)',
      () {
        final src = File('lib/app/routes.dart').readAsStringSync();
        final consts = RegExp(r"static const \w+ = '([^']+)';")
            .allMatches(src)
            .map((m) => m.group(1)!)
            .toSet();
        expect(consts.length, greaterThan(20));
        final menu = tabletMenuRoutes;
        final missing = consts
            .where((p) => !menu.contains(p) && !exempt.containsKey(p))
            .toList();
        expect(
          missing,
          isEmpty,
          reason:
              'Bu rotalar tablet sol menüsünde yok '
              '(lib/app/tablet_menu.dart): $missing',
        );
        // Menüde olmayan rota uydurulmamış.
        expect(menu.difference(consts), isEmpty);
      },
    );

    test('kimlikler ve rotalar tekil, grup boş değil', () {
      final ids = entries.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final g in tabletMenuGroups) {
        expect(g.entries, isNotEmpty, reason: g.title);
      }
    });
  });

  group('gerçek routerProvider', () {
    testWidgets('menüden açılan sayfada menü kalır', (t) async {
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
      await _reveal(t, 'sessions');
      await t.tap(find.byKey(const Key('menu-sessions')));
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
