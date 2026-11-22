import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/ink/domain/ink_models.dart' show InkPoint;
import 'package:kocum/features/pdf/domain/page_coords.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/domain/page_size.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';
import 'package:kocum/features/notes/presentation/note_tool_settings.dart';

Future<AppDatabase> _db(WidgetTester t, [Size size = const Size(1200, 900)]) async {
  late AppDatabase db;
  await t.runAsync(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
  });
  addTearDown(() async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.runAsync(db.close);
  });
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  return db;
}

Future<void> _wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(WidgetTester t, AppDatabase db, String nb) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)),
    ),
  );
  await _wait(t);
}

void main() {
  group('sonsuz sayfa (saf)', () {
    test('eşik: ekrana-tam en çok 4212; eski 14040 sonsuz sayılır', () {
      expect(isInfinitePage(1984), isFalse);
      expect(isInfinitePage(4212), isFalse);
      expect(isInfinitePage(infiniteStartHeight), isTrue);
      expect(isInfinitePage(14040), isTrue);
      expect(pageDimensions(PageSizeKind.infinite).width, 1404);
      expect(PageSizeKind.infinite.label, 'Sonsuz (aşağı kayan)');
    });

    test('uzama: alt kenara 600 kala +2000, üst sınırda durur; sonsuz olmayan sayfa değişmez', () {
      expect(infiniteGrownHeight(4400, 3000), 4400);
      expect(infiniteGrownHeight(4400, 3800), 4400); // tam sınırda tetiklenmez
      expect(infiniteGrownHeight(4400, 3801), 6400);
      expect(infiniteGrownHeight(4400, 9000), 10400); // birden çok parça
      expect(infiniteGrownHeight(1984, 1900), 1984);
      expect(infiniteGrownHeight(4400, double.nan), 4400);
      expect(infiniteGrownHeight(199000, 199000), infiniteMaxHeight);
      expect(infiniteGrownHeight(infiniteMaxHeight, 199900), infiniteMaxHeight);
      expect(infiniteAtLimit(infiniteMaxHeight, 199900), isTrue);
      expect(infiniteAtLimit(6400, 6300), isFalse);
    });

    test('şablon çizgileri üstten sayılır: sayfa uzayınca yerinden oynamaz; yalnız aralık', () {
      for (final tpl in [PageTemplate.ruled, PageTemplate.grid, PageTemplate.dots]) {
        final a = infiniteTemplateLines(tpl, 1404, 4400, 56, 0, 4400);
        final b = infiniteTemplateLines(tpl, 1404, 6400, 56, 0, 4400);
        expect(b.horizontal, a.horizontal, reason: tpl.name);
        final part = infiniteTemplateLines(tpl, 1404, 200000, 56, 100000, 100500);
        expect(part.horizontal.length, lessThan(12));
        expect(part.horizontal.every((y) => y >= 100000 && y <= 100500), isTrue);
      }
      expect(infiniteTemplateLines(PageTemplate.plain, 1404, 4400, 56, 0, 4400).isEmpty, isTrue);
      expect(infiniteTemplateLines(PageTemplate.ruled, 1404, 4400, 56, 0, 4400).horizontal.first, 112);
    });
  });

  group('depo ve editör', () {
    testWidgets('yeni defter sonsuz boyutla açılır; çizim alta yaklaşınca sayfa uzar, çizgi yerinde kalır', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb, pageId;
      await t.runAsync(() async {
        final d = pageDimensions(PageSizeKind.infinite);
        nb = await repo.createNotebook(pageWidth: d.width, pageHeight: d.height);
        final p = (await repo.pages(nb)).single;
        pageId = p.id;
        await InkStrokeRepository(db).add(
          owner: NotePageOwner(p.id, p.pageNo),
          points: const [StrokePoint(100, 3000), StrokePoint(300, 3900)],
          startedAtMs: 1,
        );
      });
      await _mount(t, db, nb);
      final page = (await t.runAsync(() => repo.findPage(pageId)))!;
      expect(page.height, infiniteStartHeight + infiniteGrowStep);
      expect(page.width, 1404);
      expect(t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data, '1 / 1 · Sonsuz');
      // Çizgi koordinatı değişmedi.
      final strokes = await t.runAsync(() => InkStrokeRepository(db).forPage(NotePageOwner(pageId, page.pageNo)));
      expect(strokes!.single.points.last.y, 3900);
    });

    testWidgets('kalem basılı/havada (görünüm kilidi) iken uzamaz; kalkınca uzar', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb, pageId;
      await t.runAsync(() async {
        final d = pageDimensions(PageSizeKind.infinite);
        nb = await repo.createNotebook(pageWidth: d.width, pageHeight: d.height);
        final p = (await repo.pages(nb)).single;
        pageId = p.id;
      });
      await _mount(t, db, nb);
      final state = t.state<NotePageEditorState>(find.byType(NotePageEditor));
      state.session.viewerLocked.value = true;
      final coords = PageCoords.tryCreate(
        pageWidth: 1404,
        pageHeight: infiniteStartHeight,
        viewWidth: 1404,
        viewHeight: infiniteStartHeight,
      )!;
      state.session.addStroke(
        0,
        state.session.brush,
        const [InkPoint(x: 100, y: 4000), InkPoint(x: 300, y: 4300, tMs: 10)],
        coords,
      );
      await _wait(t);
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, infiniteStartHeight);
      state.session.viewerLocked.value = false;
      await _wait(t);
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, infiniteStartHeight + infiniteGrowStep);
    });

    testWidgets('eski 14040 sayfa sonsuz sayılır', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb, pageId;
      await t.runAsync(() async {
        nb = await repo.createNotebook(pageWidth: 1404, pageHeight: 14040);
        final p = (await repo.pages(nb)).single;
        pageId = p.id;
        await InkStrokeRepository(db).add(
          owner: NotePageOwner(p.id, p.pageNo),
          points: const [StrokePoint(1, 13800), StrokePoint(5, 13900)],
          startedAtMs: 1,
        );
      });
      await _mount(t, db, nb);
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, 16040);
    });

    testWidgets('A4 sayfa alta yaklaşsa da uzamaz', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb2, p2;
      await t.runAsync(() async {
        nb2 = await repo.createNotebook();
        final p = (await repo.pages(nb2)).single;
        p2 = p.id;
        await InkStrokeRepository(db).add(
          owner: NotePageOwner(p.id, p.pageNo),
          points: const [StrokePoint(1, 1), StrokePoint(1, 1980)],
          startedAtMs: 1,
        );
      });
      await _mount(t, db, nb2);
      expect((await t.runAsync(() => repo.findPage(p2)))!.height, 1984);
    });

    testWidgets('boyut seçicide üç seçenek; sayfa menüsünden sonsuza geçilir', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb;
      await t.runAsync(() async => nb = await repo.createNotebook());
      await _mount(t, db, nb);
      await t.tap(find.byKey(const Key('note-page-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-page-size')));
      await t.pumpAndSettle();
      for (final k in ['a4', 'screen', 'infinite']) {
        expect(find.byKey(Key('page-size-$k')), findsOneWidget);
      }
      expect(find.textContaining('Sonsuz (aşağı kayan)'), findsOneWidget);
      expect(find.textContaining('14040'), findsNothing);
      await t.tap(find.byKey(const Key('page-size-infinite')));
      await t.tap(find.byKey(const Key('page-size-ok')));
      await _wait(t);
      expect((await t.runAsync(() async => (await repo.pages(nb)).single.height))!, infiniteStartHeight);
    });
  });

  group('yuva yerleşimi (4 kenar)', () {
    InkNotePageRecord rec() => InkNotePageRecord(
      id: 'p1',
      notebookId: 'n1',
      pageNo: 0,
      sortOrder: 0,
      template: PageTemplate.ruled,
      width: 1404,
      height: infiniteStartHeight,
      background: 0xFFFFFFFF,
      deleted: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    for (final size in const [Size(1250, 2000), Size(2000, 1250), Size(412, 915)]) {
      testWidgets('dört konumda taşma yok, sayfa tam genişlik, yuva kenarda (${size.width.toInt()})', (t) async {
        final db = await _db(t, size);
        final tools = NoteToolSettings();
        addTearDown(tools.dispose);
        await t.pumpWidget(
          ProviderScope(
            overrides: [appDatabaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              home: Scaffold(
                body: NotePageEditor(
                  key: const ValueKey('p1'),
                  page: rec(),
                  tools: tools,
                  stylusOnlyOverride: true,
                  onTemplate: (_) {},
                  onTemplateAll: (_) {},
                  onBackground: (_) {},
                  onSpacing: (_) {},
                ),
              ),
            ),
          ),
        );
        await _wait(t, 3);
        final view = t.getRect(find.byType(InteractiveViewer));
        for (final pos in DockPosition.values) {
          tools.setDockPosition(pos);
          await t.pumpAndSettle();
          expect(t.takeException(), isNull, reason: '${pos.name} ${size.width}');
          final dock = t.getRect(find.byKey(const Key('note-dock')));
          final paper = t.getRect(find.byKey(const Key('note-page-ink')));
          expect(paper.width, closeTo(view.width, 0.5), reason: pos.name);
          expect(dock.left, greaterThanOrEqualTo(view.left - 0.5), reason: pos.name);
          expect(dock.right, lessThanOrEqualTo(view.right + 0.5), reason: pos.name);
          expect(dock.top, greaterThanOrEqualTo(view.top - 0.5), reason: pos.name);
          expect(dock.bottom, lessThanOrEqualTo(view.bottom + 0.5), reason: pos.name);
          switch (pos) {
            case DockPosition.top:
              expect(dock.top, lessThan(view.top + 40));
              expect(dock.center.dx, closeTo(view.center.dx, 2));
            case DockPosition.bottom:
              expect(dock.bottom, greaterThan(view.bottom - 40));
              expect(dock.center.dx, closeTo(view.center.dx, 2));
            case DockPosition.left:
              expect(dock.left, lessThan(view.left + 40));
            case DockPosition.right:
              expect(dock.right, greaterThan(view.right - 40));
          }
          // Zum göstergesi yuvayla çakışmaz.
          final zoom = t.getRect(find.byKey(const Key('note-zoom-fit')));
          expect(zoom.overlaps(dock), isFalse, reason: pos.name);
        }
      });
    }
  });
}
