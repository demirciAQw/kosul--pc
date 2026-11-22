import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:kocum/app/app_shell.dart';
import 'package:kocum/app/router.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_models.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/note_ink_toolbar.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';
import 'package:kocum/features/pdf/presentation/pdf_ink_session.dart';
import 'package:kocum/features/pdf/presentation/pdf_reader_page.dart';
import 'package:kocum/features/question_bank/question_bank_providers.dart';

Widget _page(String t) => Scaffold(
  appBar: AppBar(title: Text(t)),
  body: Center(child: Text('sayfa-$t')),
);

GoRouter _router() => GoRouter(
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (c, s, shell) => AppShell(shell: shell),
      branches: [
        for (final p in [
          '/',
          '/anlik',
          '/books',
          '/notebook',
          '/mock',
          '/insights',
        ])
          StatefulShellBranch(
            routes: [GoRoute(path: p, builder: (c, s) => _page(p))],
          ),
      ],
    ),
    GoRoute(
      path: '/pdf',
      builder: (c, s) => TabletFrame(
        selected: RailItem.kitaplik,
        child: Scaffold(
          appBar: AppBar(actions: const [FocusModeButton()]),
          body: const Text('sayfa-pdf'),
        ),
      ),
    ),
    GoRoute(
      path: '/defter',
      builder: (c, s) =>
          TabletFrame(selected: RailItem.defterler, child: _page('defter')),
    ),
    GoRoute(path: '/settings', builder: (c, s) => _page('settings')),
  ],
);

Future<void> _pump(
  WidgetTester t,
  Widget app,
  Size size, {
  bool android = true,
}) async {
  debugAndroidOverride = android;
  addTearDown(() => debugAndroidOverride = null);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(app);
  await t.pump();
}

/// Gerçek ana sayfa süresiz akış/animasyon tutar: `pumpAndSettle` bitmez.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Ağacı sök, Drift akışlarının kapanış zamanlayıcıları işlesin.
Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(() => Future.delayed(const Duration(milliseconds: 20)));
  await t.pump(const Duration(milliseconds: 20));
}

Widget _app(GoRouter r) => ProviderScope(
  overrides: [dueCountProvider.overrideWith((ref) => Stream.value(3))],
  child: MaterialApp.router(routerConfig: r),
);

void main() {
  group('isTabletLayout', () {
    test('telefon (dikey ve yatay)', () {
      expect(isTabletLayout(const Size(412, 915), android: true), isFalse);
      expect(isTabletLayout(const Size(915, 412), android: true), isFalse);
    });
    test('katlanabilir: kapalı dış ekran telefon, açık iç ekran tablet', () {
      expect(isTabletLayout(const Size(360, 800), android: true), isFalse);
      expect(isTabletLayout(const Size(673, 841), android: true), isTrue);
    });
    test('tablet (Casper PAD H10 ~1280x800 dp, dikey ve yatay) ve sınır', () {
      expect(isTabletLayout(const Size(1280, 800), android: true), isTrue);
      expect(isTabletLayout(const Size(800, 1280), android: true), isTrue);
      expect(isTabletLayout(const Size(600, 1024), android: true), isTrue);
      expect(isTabletLayout(const Size(599.9, 1024), android: true), isFalse);
    });
    test('Android değilse tablet düzeni yok', () {
      expect(isTabletLayout(const Size(1280, 800), android: false), isFalse);
    });
  });

  group('kabuk', () {
    testWidgets('tablette ray görünür, alt çubuk yok; gezinme çalışır', (
      t,
    ) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, _app(r), const Size(1280, 800));
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('3'), findsOneWidget); // tekrar rozeti

      await t.tap(find.byKey(const Key('rail-notlar')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-/anlik'), findsOneWidget);
      await t.tap(find.byKey(const Key('rail-soruDefteri')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-/notebook'), findsOneWidget);
      await t.tap(find.byKey(const Key('rail-daha-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('rail-more-insights')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-/insights'), findsOneWidget);
      await t.tap(find.byKey(const Key('rail-kitaplik')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-pdf'), findsOneWidget);
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      await t.tap(find.byKey(const Key('rail-defterler')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-defter'), findsOneWidget);
      await t.tap(find.byKey(const Key('rail-ayarlar')));
      await t.pumpAndSettle();
      expect(find.text('sayfa-settings'), findsOneWidget);
    });

    testWidgets('telefonda ray yok, alt çubuk var', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, _app(r), const Size(412, 915));
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('Android olmayan geniş ekranda ray yok', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, _app(r), const Size(1280, 800), android: false);
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets(
      'odak modu rayı gizler, düğme geri getirir; telefonda düğme yok',
      (t) async {
        final r = _router();
        addTearDown(r.dispose);
        await _pump(t, _app(r), const Size(1280, 800));
        r.go('/pdf');
        await t.pumpAndSettle();
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
        await t.tap(find.byKey(const Key('focus-mode')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('tablet-rail')), findsNothing);
        await t.tap(find.byKey(const Key('focus-mode')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      },
    );

    testWidgets('telefonda çerçeve sarmaz, odak düğmesi görünmez', (t) async {
      final r = _router();
      addTearDown(r.dispose);
      await _pump(t, _app(r), const Size(412, 915));
      r.go('/pdf');
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
      expect(find.byKey(const Key('focus-mode')), findsNothing);
      expect(find.text('sayfa-pdf'), findsOneWidget);
    });
  });

  group('araç çubuğu tek satır, taşma yok', () {
    for (final size in const [
      Size(1280, 800),
      Size(800, 1280),
      Size(600, 1024),
    ]) {
      testWidgets('NoteInkToolbar ${size.width.toInt()}', (t) async {
        final tools = NoteToolSettings();
        addTearDown(tools.dispose);
        await _pump(
          t,
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  NoteInkToolbar(
                    tools: tools,
                    session: null,
                    template: PageTemplate.values.first,
                    onTemplate: (_) {},
                    onTemplateAll: (_) {},
                  ),
                ],
              ),
            ),
          ),
          size,
        );
        expect(t.takeException(), isNull);
        expect(t.getSize(find.byType(NoteInkToolbar)).height, lessThan(64));
        final wide = size.width >= kToolbarCompactWidth;
        expect(
          find.byKey(const Key('note-more')),
          wide ? findsNothing : findsOneWidget,
        );
        // Şekil ve Boyut her genişlikte görünür; yalnız sertlik "…" menüsüne iner.
        expect(find.byKey(const Key('note-shape')), findsOneWidget);
        expect(find.byKey(const Key('note-size')), findsOneWidget);
        expect(find.byKey(const Key('note-pen-highlighter')), findsOneWidget);
      });

      testWidgets('PdfInkToolbar ${size.width.toInt()}', (t) async {
        late AppDatabase db;
        late PdfInkSession session;
        await t.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          await db.customSelect('SELECT 1').get();
          session = PdfInkSession(
            documentId: 'd' * 64,
            repository: InkStrokeRepository(db),
          );
        });
        addTearDown(() => t.runAsync(db.close));
        addTearDown(session.dispose);
        await _pump(
          t,
          MaterialApp(
            home: Scaffold(
              body: PdfInkToolbar(
                session: session,
                tool: InkTool.pen,
                onSelect: () {},
                color: 0xFF000000,
                width: 4,
                onTool: (_) {},
                onColor: (_) {},
                onWidth: (_) {},
              ),
            ),
          ),
          size,
        );
        expect(t.takeException(), isNull);
        expect(t.getSize(find.byType(PdfInkToolbar)).height, lessThan(64));
        final wide = size.width >= kToolbarCompactWidth;
        expect(
          find.byKey(const Key('pdf-more')),
          wide ? findsNothing : findsOneWidget,
        );
        expect(find.byKey(const Key('pdf-undo')), findsOneWidget);
        expect(find.byKey(const Key('pdf-tool-select')), findsOneWidget);
      });
    }

    testWidgets('telefonda araç çubuğu eskisi gibi (… menüsü yok)', (t) async {
      final tools = NoteToolSettings();
      addTearDown(tools.dispose);
      await _pump(
        t,
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                NoteInkToolbar(
                  tools: tools,
                  session: null,
                  template: PageTemplate.values.first,
                  onTemplate: (_) {},
                  onTemplateAll: (_) {},
                ),
              ],
            ),
          ),
        ),
        const Size(412, 915),
      );
      expect(find.byKey(const Key('note-more')), findsNothing);
      expect(find.byKey(const Key('note-shape')), findsOneWidget);
    });
  });

  group('durum ve gezinme (tablet↔telefon, geri tuşu, odak)', () {
    testWidgets('tablet↔telefon boyut değişince çocuğun State\'i korunur', (
      t,
    ) async {
      final r = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (c, s) => const TabletFrame(
              selected: RailItem.kitaplik,
              child: _Counter(),
            ),
          ),
        ],
      );
      addTearDown(r.dispose);
      await _pump(t, _app(r), const Size(1280, 800));
      await t.tap(find.byKey(const Key('counter')));
      await t.pump();
      expect(find.text('n=1'), findsOneWidget);
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      t.view.physicalSize = const Size(412, 915);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsNothing);
      expect(find.text('n=1'), findsOneWidget);
      t.view.physicalSize = const Size(1280, 800);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
      expect(find.text('n=1'), findsOneWidget);
    });

    group('gerçek routerProvider', () {
      late AppDatabase db;
      late List<SystemUiMode> modes;
      late Future<void> Function(SystemUiMode) oldSetter;

      setUp(() {
        modes = [];
        oldSetter = systemUiModeSetter;
        systemUiModeSetter = (m) async => modes.add(m);
      });
      tearDown(() => systemUiModeSetter = oldSetter);

      Future<GoRouter> boot(WidgetTester t, Size size) async {
        await t.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
          await db.customSelect('SELECT 1').get();
        });
        // Gerçek ana sayfanın açık Drift akışları close()'u bekletir; bellekte
        // veritabanı olduğu için kapatılmaz, ağaç söküldükten sonra çöpe gider.
        addTearDown(() => t.runAsync(db.close));
        late GoRouter router;
        final app = ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: Consumer(
            builder: (c, ref, _) {
              router = ref.watch(routerProvider);
              return MaterialApp.router(routerConfig: router);
            },
          ),
        );
        await _pump(t, app, size);
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
        await t.pump();
        return router;
      }

      testWidgets('ray bağlantıları; geri tuşu Kitaplık\'tan ana sayfaya', (
        t,
      ) async {
        final r = await boot(t, const Size(1280, 800));
        await t.tap(find.byKey(const Key('rail-kitaplik')));
        await _settle(t);
        expect(r.state.uri.path, '/pdf');
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
        await t.tap(find.byKey(const Key('rail-defterler')));
        await _settle(t);
        expect(r.state.uri.path, '/defter');
        expect(find.byKey(const Key('tablet-rail')), findsOneWidget);
        // Geri tuşu: uygulama kapanmaz, ana sayfaya gider.
        await t.binding.handlePopRoute();
        await _settle(t);
        expect(r.state.uri.path, '/');
        expect(find.byType(AppShell), findsOneWidget);
        await _unmount(t);
      });

      testWidgets('odak: giriş, çıkış, alt sayfaya geçiş, eşik altı, dispose', (
        t,
      ) async {
        final r = await boot(t, const Size(1280, 800));
        r.go('/pdf');
        await _settle(t);
        // Çerçevenin altındaki herhangi bir öğeden odak durumuna ulaş.
        final inner = t.element(find.byType(KeyedSubtree).first);
        final n = TabletFocus.maybeOf(inner)!;
        modes.clear();
        n.value = true;
        await _settle(t);
        expect(modes.last, SystemUiMode.immersiveSticky);
        expect(find.byKey(const Key('tablet-rail')), findsNothing);
        n.value = false;
        await _settle(t);
        expect(modes.last, SystemUiMode.edgeToEdge);

        // Alt sayfa açılınca odak kapanır, çubuklar gelir.
        n.value = true;
        await _settle(t);
        modes.clear();
        unawaited(r.push('/settings'));
        await _settle(t);
        expect(modes, contains(SystemUiMode.edgeToEdge));
        expect(n.value, isFalse);
        await _unmount(t);
      });

      testWidgets('eşik altına inince odak kapanır, çubuklar gelir', (t) async {
        final r = await boot(t, const Size(1280, 800));
        r.go('/pdf');
        await _settle(t);
        final n = TabletFocus.maybeOf(
          t.element(find.byType(KeyedSubtree).first),
        )!;
        n.value = true;
        await _settle(t);
        modes.clear();
        t.view.physicalSize = const Size(412, 915);
        await _settle(t);
        expect(modes, contains(SystemUiMode.edgeToEdge));
        expect(n.value, isFalse);
        await _unmount(t);
      });

      testWidgets('odak açıkken çerçeve kalkarsa çubuklar geri gelir', (
        t,
      ) async {
        final r = await boot(t, const Size(1280, 800));
        r.go('/pdf');
        await _settle(t);
        TabletFocus.maybeOf(t.element(find.byType(KeyedSubtree).first))!.value =
            true;
        await _settle(t);
        modes.clear();
        r.go('/');
        await _settle(t);
        expect(modes.last, SystemUiMode.edgeToEdge);
        await _unmount(t);
      });
    });
  });

  group('"…" menüsü gerçekten değer değiştirir', () {
    Future<NoteToolSettings> open(WidgetTester t) async {
      final tools = NoteToolSettings();
      addTearDown(tools.dispose);
      await _pump(
        t,
        MaterialApp(
          home: Scaffold(
            body: NoteInkToolbar(
              tools: tools,
              session: null,
              template: PageTemplate.values.first,
              onTemplate: (_) {},
              onTemplateAll: (_) {},
            ),
          ),
        ),
        const Size(800, 1280),
      );
      await t.tap(find.byKey(const Key('note-more')));
      await t.pumpAndSettle();
      return tools;
    }

    testWidgets('sertlik sürgüsü etkin, değeri değiştirir, menü açık kalır', (
      t,
    ) async {
      final tools = await open(t);
      final slider = find.byKey(const Key('note-hardness'));
      expect(slider, findsOneWidget);
      final before = tools.hardness;
      await t.drag(slider, const Offset(60, 0));
      await t.pumpAndSettle();
      expect(tools.hardness, greaterThan(before));
      await t.tapAt(t.getTopLeft(slider) + const Offset(10, 24));
      await t.pumpAndSettle();
      expect(tools.hardness, lessThan(0.2));
      expect(find.byKey(const Key('note-hardness')), findsOneWidget);
    });

    testWidgets('Şekil penceresindeki anahtar değeri değiştirir', (t) async {
      final tools = await open(t);
      await t.tapAt(const Offset(1, 1)); // "…" menüsünü kapat
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-shape')));
      await t.pumpAndSettle();
      final was = tools.shapeSnap;
      await t.tap(find.byKey(const Key('note-shape-snap')));
      await t.pumpAndSettle();
      expect(tools.shapeSnap, !was);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: TextButton(
      key: const Key('counter'),
      onPressed: () => setState(() => n++),
      child: Text('n=$n'),
    ),
  );
}
