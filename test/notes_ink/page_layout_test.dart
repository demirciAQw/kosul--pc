import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/app/tablet.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/ink/domain/stroke_codec.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/domain/page_size.dart';
import 'package:kocum/features/notes/domain/page_template.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';
import 'package:kocum/features/notes/presentation/notebooks_screen.dart';
import 'package:kocum/features/notes/presentation/page_template_painter.dart';

Future<AppDatabase> _db(WidgetTester t) async {
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
  t.view.physicalSize = const Size(1200, 900);
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

Future<void> _mount(WidgetTester t, AppDatabase db, String nb, {ValueNotifier<bool>? focus}) async {
  Widget home = InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true);
  if (focus != null) home = TabletFocus(focus: focus, child: home);
  await t.pumpWidget(
    ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp(home: home),
    ),
  );
  await _wait(t);
}

String _indicator(WidgetTester t) => t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data!;

double _scale(WidgetTester t) =>
    t.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!.value.getMaxScaleOnAxis();

void main() {
  group('sayfa boyutu (saf)', () {
    test('A4, ekrana tam ve sınırsız boyutları; genişlik hep 1404', () {
      expect(pageDimensions(PageSizeKind.a4), (width: 1404.0, height: 1984.0));
      expect(pageDimensions(PageSizeKind.free), (width: 1404.0, height: 14040.0));
      // 1600x2560 tablet: oran 1.6.
      expect(screenAspect(1600, 2560), 1.6);
      expect(screenAspect(2560, 1600), 1.6); // yatay da dikey sayılır
      expect(pageDimensions(PageSizeKind.screen, aspect: 1.6), (width: 1404.0, height: 2246.0));
      // Aşırı oran kırpılır; geçersiz boyut A4 oranı verir.
      expect(pageDimensions(PageSizeKind.screen, aspect: 9).height, 1404 * 3);
      expect(screenAspect(0, 10), closeTo(1984 / 1404, 1e-9));
    });

    test('kayıtlı boyuttan tür tahmini', () {
      expect(pageSizeKindOf(1404, 1984), PageSizeKind.a4);
      expect(pageSizeKindOf(1404, 2246), PageSizeKind.screen);
      expect(pageSizeKindOf(1404, 14040), PageSizeKind.free);
    });

    test('noktalı şablon: kareli ile aynı konumlar; anahtar çevirisi', () {
      final g = templateLines(PageTemplate.grid, 1404, 1984);
      final d = templateLines(PageTemplate.dots, 1404, 1984);
      expect(d.horizontal, g.horizontal);
      expect(d.vertical, g.vertical);
      expect(d.isEmpty, isFalse);
      expect(PageTemplate.fromKey('dots'), PageTemplate.dots);
      expect(templateLabel(PageTemplate.dots), 'Noktalı');
    });

    test('sınırsız tuvalde çizgi sayısı makul', () {
      final l = templateLines(PageTemplate.ruled, 1404, freePageHeight);
      expect(l.horizontal.length, lessThan(400));
    });
  });

  group('depo: boyut', () {
    Future<(AppDatabase, InkNotebookRepository)> open(WidgetTester t) async {
      final db = await _db(t);
      return (db, InkNotebookRepository(db));
    }

    testWidgets('defter boyutla açılır; sayfa eklenince son sayfanın boyutunu miras alır; şablon varsayılandan', (t) async {
      final (_, repo) = await open(t);
      late List<double> sizes;
      late PageTemplate tpl;
      await t.runAsync(() async {
        final nb = await repo.createNotebook(
          defaultTemplate: PageTemplate.dots,
          pageWidth: 1404,
          pageHeight: freePageHeight,
        );
        await repo.addPage(nb);
        final pages = await repo.pages(nb);
        sizes = [for (final p in pages) p.height];
        tpl = pages.last.template;
      });
      expect(sizes, [freePageHeight, freePageHeight]);
      expect(tpl, PageTemplate.dots);
    });

    testWidgets('setPageSize: büyütme serbest; küçültme çizgiyi kırpacaksa engellenir, yoksa olur', (t) async {
      final (db, repo) = await open(t);
      final strokes = InkStrokeRepository(db);
      late String nb, pageId;
      await t.runAsync(() async {
        nb = await repo.createNotebook();
        final p = (await repo.pages(nb)).single;
        pageId = p.id;
        await strokes.add(
          owner: NotePageOwner(p.id, p.pageNo),
          points: const [StrokePoint(100, 100), StrokePoint(300, 1500)],
          startedAtMs: 1,
        );
      });
      Future<Object?> run(double w, double h) async {
        Object? err;
        await t.runAsync(() async {
          try {
            await repo.setPageSize(pageId, w, h);
          } catch (e) {
            err = e;
          }
        });
        return err;
      }

      expect(await run(1404, freePageHeight), isNull);
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, freePageHeight);
      // Çizgi y=1500'de: 1400'e küçültme engellenir, boyut aynı kalır.
      expect(await run(1404, 1400), isA<StateError>());
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, freePageHeight);
      // Çizgiyi saran küçültme serbest.
      expect(await run(1404, 1984), isNull);
      expect((await t.runAsync(() => repo.findPage(pageId)))!.height, 1984);
      expect(await run(1404, 0), isA<ArgumentError>());
    });
  });

  group('ekran', () {
    testWidgets('yeni defter diyaloğu: şablon ve boyut seçilir, defter ona göre oluşur', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      t.view.physicalSize = const Size(1600, 2560); // tablet oranı 1.6
      await t.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: NotebooksScreen(onOpen: _noop)),
        ),
      );
      await _wait(t);
      await t.tap(find.byKey(const Key('notebook-new')));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('notebook-title-field')), 'Matematik');
      await t.tap(find.byKey(const Key('notebook-template-dots')));
      await t.tap(find.byKey(const Key('page-size-screen')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notebook-dialog-ok')));
      await _wait(t);
      late List<InkNotePageRecord> pages;
      late InkNotebookRecord nb;
      await t.runAsync(() async {
        nb = (await repo.notebooks()).single;
        pages = await repo.pages(nb.id);
      });
      expect(nb.defaultTemplate, PageTemplate.dots);
      expect(pages.single.template, PageTemplate.dots);
      expect(pages.single.width, 1404);
      expect(pages.single.height, 2246);
    });

    testWidgets('varsayılan: çizgili, A4', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      await t.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: const MaterialApp(home: NotebooksScreen(onOpen: _noop)),
        ),
      );
      await _wait(t);
      await t.tap(find.byKey(const Key('notebook-new')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('notebook-dialog-ok')));
      await _wait(t);
      late InkNotePageRecord p;
      await t.runAsync(() async => p = (await repo.pages((await repo.notebooks()).single.id)).single);
      expect(p.template, PageTemplate.ruled);
      expect(p.height, 1984);
    });

    testWidgets('"Yeni sayfa" düğmesi görünür: 1 sayfalı defter 1/1 -> 2/2', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      expect(_indicator(t), '1 / 1');
      expect(find.text('Yeni sayfa'), findsNothing); // şerit varsayılan kapalı
      await t.tap(find.byKey(const Key('note-strip-toggle')));
      await t.pumpAndSettle();
      expect(find.text('Yeni sayfa'), findsOneWidget);
      await t.tap(find.byKey(const Key('note-strip-add')));
      await _wait(t);
      expect(_indicator(t), '2 / 2');
    });

    testWidgets('ok düğmeleri: geri/ileri; son sayfada ileri yeni sayfa ekler', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      expect(t.widget<IconButton>(find.byKey(const Key('note-page-prev'))).onPressed, isNull);
      await t.tap(find.byKey(const Key('note-page-next'))); // son sayfa: ekler
      await _wait(t);
      expect(_indicator(t), '2 / 2');
      await t.tap(find.byKey(const Key('note-page-prev')));
      await _wait(t);
      expect(_indicator(t), '1 / 2');
      await t.tap(find.byKey(const Key('note-page-next')));
      await _wait(t);
      expect(_indicator(t), '2 / 2'); // yeni sayfa eklenmedi, ileri gitti
    });

    testWidgets('odak modu şeridi gizler, çıkınca geri gelir', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      final focus = ValueNotifier(false);
      await _mount(t, db, nb, focus: focus);
      expect(find.byKey(const Key('note-page-strip')), findsNothing); // varsayılan kapalı
      await t.tap(find.byKey(const Key('note-strip-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-page-strip')), findsOneWidget);
      focus.value = true;
      await t.pump();
      expect(find.byKey(const Key('note-page-strip')), findsNothing);
      focus.value = false;
      await t.pump();
      expect(find.byKey(const Key('note-page-strip')), findsOneWidget);
    });

    testWidgets('sayfa genişliğe tam oturur (şerit gizliyken görünüm genişliği kadar)', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      final paper = t.getRect(find.byKey(const Key('note-page-ink')));
      final view = t.getRect(find.byType(InteractiveViewer));
      expect(paper.width, closeTo(view.width, 0.5));
      expect(paper.height / paper.width, closeTo(1984 / 1404, 0.001));
    });

    testWidgets('zum: geniş aralık, yüzde göstergesi, sığdır düğmesi ve çift dokunuş; çizgi koordinatı bozulmaz', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      final iv = t.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(iv.minScale, 0.1);
      expect(iv.maxScale, 30);
      expect(iv.boundaryMargin, const EdgeInsets.all(double.infinity));
      expect(t.widget<Text>(find.byKey(const Key('note-zoom-label'))).data, '%100');

      final ctl = iv.transformationController!;
      final state = t.state<NotePageEditorState>(find.byType(NotePageEditor));
      ctl.value = Matrix4.identity()
        ..translateByDouble(-300, -200, 0, 1)
        ..scaleByDouble(8, 8, 8, 1);
      await t.pump();
      expect(_scale(t), closeTo(8, 1e-9));
      expect(t.widget<Text>(find.byKey(const Key('note-zoom-label'))).data, '%800');

      await t.tap(find.byKey(const Key('note-zoom-fit')));
      await t.pump();
      expect(ctl.value.isIdentity(), isTrue);

      // Çift dokunuş: sığdırılmışken önceki zum yoksa değişmez; zumluyken sığdırır, tekrar çift dokunuş geri getirir.
      final zoomed = Matrix4.identity()..scaleByDouble(3, 3, 3, 1);
      ctl.value = zoomed.clone();
      await t.pump();
      state.toggleFit();
      expect(ctl.value.isIdentity(), isTrue);
      state.toggleFit();
      expect(ctl.value, zoomed);

      // Gerçek çift dokunuş (parmak).
      final c = t.getCenter(find.byType(InteractiveViewer));
      await t.tapAt(c);
      await t.pump(const Duration(milliseconds: 50));
      await t.tapAt(c);
      await t.pumpAndSettle();
      expect(ctl.value.isIdentity(), isTrue);
    });

    testWidgets('sayfa boyutu menüsü: sınırsıza büyütme; çizgi varken küçültme engellenir', (t) async {
      final db = await _db(t);
      final repo = InkNotebookRepository(db);
      late String nb;
      await t.runAsync(() async {
        nb = await repo.createNotebook(title: 'Bir');
        final p = (await repo.pages(nb)).single;
        await InkStrokeRepository(db).add(
          owner: NotePageOwner(p.id, p.pageNo),
          points: const [StrokePoint(100, 100), StrokePoint(300, 1800)],
          startedAtMs: 1,
        );
      });
      await _mount(t, db, nb);
      Future<void> choose(String key) async {
        await t.tap(find.byKey(const Key('note-page-menu')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('note-page-size')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(Key(key)));
        await t.tap(find.byKey(const Key('page-size-ok')));
        await _wait(t);
      }

      Future<double> height() async => (await t.runAsync(() async => (await repo.pages(nb)).single.height))!;
      await choose('page-size-free');
      expect(await height(), freePageHeight);
      // Ekran oranı 1.2 (1200x1000): ekrana tam = 1685 yüksek; çizgi y=1800'de, engellenir.
      t.view.physicalSize = const Size(1200, 1000);
      await t.pumpAndSettle();
      await choose('page-size-screen');
      expect(find.textContaining('küçültülemez'), findsOneWidget);
      expect(await height(), freePageHeight);
      await choose('page-size-a4');
      expect(await height(), 1984);
    });
  });

  group('araç yuvası ve üst çubuk (ekran)', () {
    Future<(AppDatabase, String)> setup(WidgetTester t, Size size) async {
      final db = await _db(t);
      t.view.physicalSize = size;
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      return (db, nb);
    }

    for (final size in const [Size(1250, 2000), Size(2000, 1250), Size(412, 915)]) {
      testWidgets('taşma yok, şerit kapalı, sayfa tam genişlik, yuva sayfanın üstünde (${size.width.toInt()})', (t) async {
        await setup(t, size);
        expect(t.takeException(), isNull);
        expect(find.byKey(const Key('note-dock')), findsOneWidget);
        expect(find.byKey(const Key('note-page-strip')), findsNothing);
        final paper = t.getRect(find.byKey(const Key('note-page-ink')));
        final view = t.getRect(find.byType(InteractiveViewer));
        expect(paper.width, closeTo(view.width, 0.5)); // yuva sayfa alanını daraltmaz
        final dock = t.getRect(find.byKey(const Key('note-dock')));
        expect(dock.bottom, lessThanOrEqualTo(view.bottom));
        expect(dock.width, lessThanOrEqualTo(size.width));
        // Üst çubukta sayfa göstergesi, oklar ve "+" var.
        expect(_indicator(t), '1 / 1');
        for (final k in ['note-page-prev', 'note-page-next', 'note-page-add-top', 'note-page-menu']) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        // Yuvayı üste al: taşma yok, yuva üst çubuğun altında.
        await t.tap(find.byKey(const Key('note-dock-move')));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(t.getRect(find.byKey(const Key('note-dock'))).top, lessThan(view.top + 40));
      });
    }

    testWidgets('üst çubuktaki "+" sayfa ekler; şerit düğmeyle açılıp kapanır', (t) async {
      await setup(t, const Size(1250, 2000));
      await t.tap(find.byKey(const Key('note-page-add-top')));
      await _wait(t);
      expect(_indicator(t), '2 / 2');
      await t.tap(find.byKey(const Key('note-strip-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-page-strip')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-strip-toggle')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-page-strip')), findsNothing);
    });

    testWidgets('Sayfa düğmesi: şablon, arka plan sayfa kaydını değiştirir; çizgi aralığı yalnız oturumda', (t) async {
      final (db, nb) = await setup(t, const Size(1250, 2000));
      PageTemplatePainter paper() =>
          t.widget<CustomPaint>(find.byKey(const Key('note-page-paper'))).painter! as PageTemplatePainter;
      expect(paper().template, PageTemplate.ruled);
      await t.tap(find.byKey(const Key('note-template')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-template-dots')));
      await _wait(t);
      expect(paper().template, PageTemplate.dots);
      await t.tap(find.byKey(const Key('note-bg-cream')));
      await _wait(t);
      expect(paper().background, 0xFFFFF8E1);
      await t.tap(find.byKey(const Key('note-spacing-wide')));
      await _wait(t);
      expect(paper().spacingFactor, 1.5);
      late InkNotePageRecord rec;
      await t.runAsync(() async => rec = (await InkNotebookRepository(db).pages(nb)).single);
      expect(rec.template, PageTemplate.dots);
      expect(rec.background, 0xFFFFF8E1);
      // Sayfa menüsündeki giriş aynı pencereyi açar.
      await t.tapAt(const Offset(2, 2));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-page-menu')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-page-style')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-template-grid')));
      await _wait(t);
      expect(paper().template, PageTemplate.grid);
      expect(paper().spacingFactor, 1.5); // oturum boyunca korunur
    });

    testWidgets('telefonda: etiket ve şerit sayfa menüsünde, yuva çalışır', (t) async {
      await setup(t, const Size(412, 915));
      expect(find.byKey(const Key('note-tags-btn')), findsNothing);
      expect(find.byKey(const Key('note-strip-toggle')), findsNothing);
      await t.tap(find.byKey(const Key('note-page-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-tags-menu')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-strip-menu')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-page-strip')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pump();
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('note-erase-mode')), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('silgi boyutu ve yuva konumu kalıcı: kapat, yeniden aç, geri gelir', (t) async {
      final db = await _db(t);
      late String nb;
      await t.runAsync(() async => nb = await InkNotebookRepository(db).createNotebook(title: 'Bir'));
      await _mount(t, db, nb);
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pump();
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-size-chip-44')));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(2, 2));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('note-dock-move')));
      await _wait(t); // gecikmeli kayıt
      await t.pumpWidget(const SizedBox());
      await _wait(t, 3);

      await _mount(t, db, nb);
      expect(t.state<NotePageEditorState>(find.byType(NotePageEditor)).widget.tools.dockAtTop, isTrue);
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pump();
      await t.tap(find.byKey(const Key('note-eraser')));
      await t.pumpAndSettle();
      expect(t.widget<ChoiceChip>(find.byKey(const Key('note-size-chip-44'))).selected, isTrue);
    });
  });
}

void _noop(BuildContext c, InkNotebookRecord n) {}
