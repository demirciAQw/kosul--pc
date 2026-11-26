import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/ink/data/ink_stroke_repository.dart';
import 'package:kocum/features/ink/domain/ink_stroke_record.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/data/note_view_mode_store.dart';
import 'package:kocum/features/notes/domain/flow_layout.dart';
import 'package:kocum/features/notes/domain/ink_notebook.dart';
import 'package:kocum/features/notes/presentation/ink_notebook_screen.dart';
import 'package:kocum/features/notes/presentation/note_flow_view.dart';
import 'package:kocum/features/notes/presentation/note_page_editor.dart';

void main() {
  group('FlowLayout', () {
    final l = FlowLayout([(w: 100, h: 200), (w: 100, h: 100), (w: 100, h: 200)], width: 50, gap: 10, endHeight: 40);

    test('üst konum, toplam, son kart', () {
      expect(l.heights, [100, 50, 100]);
      expect(l.tops, [0, 110, 170]);
      expect(l.endTop, 280);
      expect(l.total, 320);
    });

    test('indexAt: boşluk üstteki sayfaya, sınırlara kırpılır', () {
      expect(l.indexAt(-5), 0);
      expect(l.indexAt(105), 0);
      expect(l.indexAt(110), 1);
      expect(l.indexAt(169), 1);
      expect(l.indexAt(999), 2);
    });

    test('visibleRange: ±1 sayfa payı, sınırlı', () {
      expect(l.visibleRange(0, 50), (first: 0, last: 1));
      expect(l.visibleRange(120, 130), (first: 0, last: 2));
      expect(l.visibleRange(0, 50, margin: 0), (first: 0, last: 0));
      expect(FlowLayout(const [], width: 10).visibleRange(0, 10), (first: 0, last: -1));
    });

    test('flowNearEnd: alt %15', () {
      expect(flowNearEnd(850, 1000), isTrue);
      expect(flowNearEnd(849, 1000), isFalse);
      expect(flowNearEnd(10, 0), isFalse);
    });

    test('görünüm tercihi: varsayılan akış, bozuk değer akış', () {
      expect(NoteViewMode.parse(null), NoteViewMode.flow);
      expect(NoteViewMode.parse('tek'), NoteViewMode.single);
      expect(NoteViewMode.parse('?'), NoteViewMode.flow);
    });
  });

  group('akış ekranı', () {
    late AppDatabase db;
    late InkNotebookRepository repo;
    late InkStrokeRepository strokes;

    Future<String> setup(WidgetTester t, {int pages = 3}) async {
      late String nb;
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
        repo = InkNotebookRepository(db);
        strokes = InkStrokeRepository(db);
        nb = await repo.createNotebook(title: 'Akış');
        await repo.ensureVisiblePage(nb);
        for (var i = 1; i < pages; i++) {
          await repo.addPage(nb);
        }
      });
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 15));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.runAsync(db.close);
      });
      t.view.physicalSize = const Size(1200, 2000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      return nb;
    }

    Future<void> wait(WidgetTester t, [int n = 8]) async {
      for (var i = 0; i < n; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> mount(WidgetTester t, String nb) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [appDatabaseProvider.overrideWithValue(db)],
          child: MaterialApp(home: InkNotebookScreen(notebookId: nb, stylusOnlyOverride: true)),
        ),
      );
      await wait(t);
    }

    String indicator(WidgetTester t) => t.widget<Text>(find.byKey(const Key('note-page-indicator'))).data!;

    testWidgets('varsayılan akış: sayfalar alt alta, yalnız görünen (±1) sayfa canlı', (t) async {
      final nb = await setup(t, pages: 5);
      await mount(t, nb);
      expect(find.byKey(const Key('note-flow-content')), findsOneWidget);
      expect(find.byType(NotePageEditor), findsNothing);
      expect(indicator(t), '1 / 5');
      // 1200x2000 ekran: 1. sayfa + 2. sayfanın bir kısmı görünür, +1 pay = 3 canlı katman (5'in hepsi değil).
      expect(find.byKey(const Key('note-page-ink')), findsNWidgets(3));
      expect(find.byKey(const Key('note-flow-add')), findsOneWidget);
    });

    testWidgets('kalem görünen sayfaya çizer; dikey kaydırınca gösterge güncellenir', (t) async {
      final nb = await setup(t);
      late List<InkNotePageRecord> pg;
      await t.runAsync(() async => pg = await repo.pages(nb));
      await mount(t, nb);
      final r = t.getRect(find.byKey(const Key('note-page-ink')).first);
      final g = await t.startGesture(r.center, kind: PointerDeviceKind.stylus);
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(r.center + Offset(i * 20.0, i * 10.0));
      }
      await g.up();
      await t.pump();
      final st = t.state<NoteFlowViewState>(find.byType(NoteFlowView));
      await t.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await st.session.flush();
      });
      await t.pump();
      late List<InkStroke> rows;
      await t.runAsync(() async {
        rows = await strokes.forPage(NotePageOwner(pg[0].id, pg[0].pageNo), attemptNo: 0, layer: 0, noQuestion: true);
      });
      expect(rows, hasLength(1));

      // Parmakla yukarı kaydır: 2. sayfa görünür olur.
      await t.dragFrom(const Offset(600, 1500), const Offset(0, -1400));
      await wait(t, 12);
      expect(indicator(t), '2 / 3');
    });

    testWidgets('"Yeni sayfa" kartı sona sayfa ekler ve akış oraya kayar', (t) async {
      final nb = await setup(t, pages: 2);
      await mount(t, nb);
      final st = t.state<NoteFlowViewState>(find.byType(NoteFlowView));
      st.scrollToPage(st.pages.last.id, animate: false);
      await wait(t);
      await t.tap(find.byKey(const Key('note-flow-add')));
      await wait(t, 14);
      expect(indicator(t), '3 / 3');
    });

    testWidgets('görünüm anahtarı: tek sayfa ve kalıcılık', (t) async {
      final nb = await setup(t, pages: 2);
      await mount(t, nb);
      await t.tap(find.byKey(const Key('note-view-toggle')));
      await wait(t);
      expect(find.byType(NotePageEditor), findsOneWidget);
      expect(find.byKey(const Key('note-flow-content')), findsNothing);
      late NoteViewMode saved;
      await t.runAsync(() async => saved = await NoteViewModeStore(db).load());
      expect(saved, NoteViewMode.single);
      // Yeniden açılınca tek sayfa; anahtarla akışa dönülür.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
      await mount(t, nb);
      expect(find.byType(NotePageEditor), findsOneWidget);
      await t.tap(find.byKey(const Key('note-view-toggle')));
      await wait(t);
      expect(find.byKey(const Key('note-flow-content')), findsOneWidget);
    });

    testWidgets('son sayfanın alt %15inde yazınca öneri çipi çıkar; dokununca sayfa eklenir', (t) async {
      final nb = await setup(t, pages: 1);
      await mount(t, nb);
      expect(find.byKey(const Key('note-flow-suggest')), findsNothing);
      final r = t.getRect(find.byKey(const Key('note-page-ink')).first);
      final start = Offset(r.center.dx, r.top + r.height * 0.92);
      // Yuva/alt bölge ekranda kalsın diye sayfayı yukarı al.
      final st = t.state<NoteFlowViewState>(find.byType(NoteFlowView));
      st.scrollToPage(st.pages.first.id, animate: false);
      await t.pump();
      expect(start.dy, lessThan(2000));
      final g = await t.startGesture(start, kind: PointerDeviceKind.stylus);
      for (var i = 1; i <= 6; i++) {
        await g.moveTo(start + Offset(i * 15.0, 0));
      }
      await g.up();
      await wait(t, 2);
      expect(find.byKey(const Key('note-flow-suggest')), findsOneWidget);
      await t.tap(find.byKey(const Key('note-flow-suggest')));
      await wait(t, 12);
      expect(indicator(t), '2 / 2');
      expect(find.byKey(const Key('note-flow-suggest')), findsNothing);
    });
  });
}
