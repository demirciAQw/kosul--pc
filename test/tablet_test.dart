import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/app_shell.dart';
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
        expect(
          find.byKey(const Key('note-shape-snap')),
          wide ? findsOneWidget : findsNothing,
        );
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
      expect(find.byKey(const Key('note-shape-snap')), findsOneWidget);
    });
  });
}
