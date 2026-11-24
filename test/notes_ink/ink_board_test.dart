import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/notes/data/ink_board_repository.dart';
import 'package:kocum/features/notes/data/ink_notebook_repository.dart';
import 'package:kocum/features/notes/domain/board_view.dart';
import 'package:kocum/features/notes/domain/page_board.dart';
import 'package:kocum/features/notes/presentation/board_canvas.dart';
import 'package:kocum/features/notes/presentation/board_card.dart';
import 'package:kocum/features/notes/presentation/board_link_painter.dart';
import 'package:kocum/features/notes/presentation/ink_board_screen.dart';

BoardCard _card(String id, double x, double y, {int no = 1, String? title, String? konu, String? parent}) =>
    BoardCard(pageId: id, notebookId: 'n', pageNo: no, title: title, konuId: konu, parentPageId: parent, x: x, y: y, w: boardCardW, h: boardCardH);

PageLinkRecord _link(String id, String from, String to, {PageLinkKind kind = PageLinkKind.link, String label = '', int color = 0xFF607D8B}) =>
    PageLinkRecord(
      id: id,
      notebookId: 'n',
      fromPageId: from,
      toPageId: to,
      fromX: null,
      fromY: null,
      label: label,
      kind: kind,
      color: color,
      deleted: false,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  group('saf geometri', () {
    test('zum sınırları %2 ... %400 ve odak noktası sabit', () {
      var v = const BoardViewport();
      for (var i = 0; i < 50; i++) {
        v = v.zoomAt(100, 100, 0.5);
      }
      expect(v.scale, boardMinScale);
      for (var i = 0; i < 50; i++) {
        v = v.zoomAt(100, 100, 2);
      }
      expect(v.scale, boardMaxScale);
      final a = const BoardViewport(scale: 1, tx: 10, ty: 20);
      final w = a.toWorld(300, 200);
      final b = a.zoomAt(300, 200, 1.7);
      final s = b.toScreen(w.x, w.y);
      expect(s.x, closeTo(300, 1e-9));
      expect(s.y, closeTo(200, 1e-9));
    });

    test('sığdır: tüm kartlar görünür ölçek içinde', () {
      final rects = [const BoardRect(0, 0, 320, 420), const BoardRect(5000, 3000, 320, 420)];
      final b = boundsOf(rects)!;
      final v = BoardViewport.fit(b, 1000, 800);
      final vis = v.visibleRect(1000, 800);
      for (final r in rects) {
        expect(r.x >= vis.x && r.right <= vis.right && r.y >= vis.y && r.bottom <= vis.bottom, isTrue);
      }
      expect(v.scale >= boardMinScale && v.scale <= 1.0, isTrue);
      expect(boundsOf(const []), isNull);
    });

    test('150 kartta yalnız görünür olanlar seçilir', () {
      final rects = {for (var i = 0; i < 150; i++) 'p$i': BoardRect((i % 15) * 400.0, (i ~/ 15) * 500.0, 320, 420)};
      final all = visibleCardIds(rects, const BoardRect(-10000, -10000, 30000, 30000));
      expect(all.length, 150);
      final few = visibleCardIds(rects, const BoardRect(0, 0, 900, 600));
      expect(few.length, lessThan(10));
      expect(few, contains('p0'));
    });

    test('yerleşmemiş kartlar yerleşmişlerin altına konur', () {
      final cards = [
        _card('a', 0, 0),
        const BoardCard(pageId: 'b', notebookId: 'n', pageNo: 2),
        const BoardCard(pageId: 'c', notebookId: 'n', pageNo: 3),
      ];
      final m = placeUnplaced(cards);
      expect(m.keys, ['b', 'c']);
      expect(m['b']!.y, greaterThan(420));
      expect(m['b']!.overlaps(m['c']!), isFalse);
      expect(placeUnplaced([_card('a', 0, 0)]), isEmpty);
    });

    test('bağlantı hit-test: eğri üstü evet, uzağı hayır', () {
      const a = BoardRect(0, 0, 320, 420), b = BoardRect(800, 0, 320, 420);
      final c = curveBetween(a, b);
      final mid = c.at(0.5);
      final curves = {'l1': c};
      expect(linkAt(curves, mid.x, mid.y + 5, 14), 'l1');
      expect(linkAt(curves, mid.x, mid.y + 400, 14), isNull);
      expect(c.p0, const BoardPoint(320, 210));
      expect(c.p1, const BoardPoint(800, 210));
    });

    test('bağlantı stilleri: konu ince+kesik, child ayrı renk, link kendi rengi', () {
      final konu = linkStyleFor(_link('k', 'a', 'b', kind: PageLinkKind.konu));
      final child = linkStyleFor(_link('c', 'a', 'b', kind: PageLinkKind.child));
      final link = linkStyleFor(_link('l', 'a', 'b', color: 0xFFE53935));
      expect(konu.dashed, isTrue);
      expect(konu.width, lessThan(link.width));
      expect(link.dashed, isFalse);
      expect(child.dashed, isFalse);
      expect(child.color, isNot(link.color));
      expect(link.color, const Color(0xFFE53935));
    });

    test('kart başlığı: yoksa Sayfa N', () {
      expect(boardCardTitle(_card('a', 0, 0, no: 7)), 'Sayfa 7');
      expect(boardCardTitle(_card('a', 0, 0, title: 'Türev')), 'Türev');
    });
  });

  group('tuval', () {
    late BoardViewController ctl;
    late List<(Map<String, BoardRect>, Map<String, BoardRect>)> changes;
    late List<(String, String)> connects;
    late List<(String, BoardPoint)> empties;
    late List<String> opens;
    late List<PageLinkRecord> linkTaps;

    Future<void> pump(
      WidgetTester t,
      List<BoardCard> cards, {
      List<PageLinkRecord> links = const [],
      bool linkMode = false,
      String query = '',
      Size size = const Size(1000, 800),
    }) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      ctl = BoardViewController();
      addTearDown(ctl.dispose);
      changes = [];
      connects = [];
      empties = [];
      opens = [];
      linkTaps = [];
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BoardCanvas(
            controller: ctl,
            cards: cards,
            pages: const {},
            links: links,
            linkMode: linkMode,
            query: query,
            onOpen: opens.add,
            onChanged: (b, a) => changes.add((b, a)),
            onConnect: (f, to) => connects.add((f, to)),
            onConnectEmpty: (f, p) => empties.add((f, p)),
            onLinkTap: linkTaps.add,
          ),
        ),
      ));
      await t.pump();
      await t.pump();
    }

    Offset screen(WidgetTester t, double wx, double wy) {
      final s = ctl.viewport.value.toScreen(wx, wy);
      return t.getTopLeft(find.byKey(const Key('board-canvas'))) + Offset(s.x, s.y);
    }

    testWidgets('kart sürükleme: yalnız kart kayar, önceki/sonraki bildirilir', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 800, 0, no: 2)]);
      final sc = ctl.viewport.value.scale;
      final before = ctl.viewport.value;
      await t.dragFrom(screen(t, 100, 100), const Offset(60, 40));
      await t.pump();
      expect(ctl.viewport.value, before, reason: 'görünüm kaymamalı');
      expect(changes, hasLength(1));
      final (b, a) = changes.single;
      expect(b['a'], const BoardRect(0, 0, 320, 420));
      expect(a['a']!.x, closeTo(60 / sc, 1.0));
      expect(a['a']!.y, closeTo(40 / sc, 1.0));
      expect(opens, isEmpty);
    });

    testWidgets('boş alanı sürüklemek görünümü kaydırır; kalemle kaydırmaz', (t) async {
      await pump(t, [_card('a', 0, 0)]);
      final v0 = ctl.viewport.value;
      await t.dragFrom(const Offset(900, 700), const Offset(-50, -30));
      await t.pump();
      expect(ctl.viewport.value.tx, closeTo(v0.tx - 50, 1));
      final v1 = ctl.viewport.value;
      final g = await t.startGesture(const Offset(900, 700), kind: PointerDeviceKind.stylus);
      await g.moveBy(const Offset(-80, 0));
      await g.moveBy(const Offset(-80, 0));
      await g.up();
      await t.pump();
      expect(ctl.viewport.value, v1);
    });

    testWidgets('dokununca açar', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 800, 0, no: 2)]);
      await t.tapAt(screen(t, 900, 100));
      await t.pump();
      expect(opens, ['b']);
    });

    testWidgets('boyutlandırma köşe tutamacıyla', (t) async {
      await pump(t, [_card('a', 0, 0)]);
      final sc = ctl.viewport.value.scale;
      await t.dragFrom(screen(t, 310, 410), const Offset(50, 30));
      await t.pump();
      final a = changes.single.$2['a']!;
      expect(a.x, 0);
      expect(a.w, closeTo(320 + 50 / sc, 1.0));
      expect(a.h, closeTo(420 + 30 / sc, 1.0));
    });

    testWidgets('bağla tutamacı: karta bırak -> onConnect; boşluğa -> onConnectEmpty', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 800, 0, no: 2)]);
      final from = screen(t, 320, 210);
      final to = screen(t, 900, 200);
      await t.dragFrom(from, to - from);
      await t.pump();
      expect(connects, [('a', 'b')]);
      expect(changes, isEmpty);

      final empty = screen(t, 500, 900);
      await t.dragFrom(from, empty - from);
      await t.pump();
      expect(empties, hasLength(1));
      expect(empties.single.$1, 'a');
      expect(empties.single.$2.x, closeTo(500, 2));
      expect(connects, hasLength(1));
    });

    testWidgets('bağlantı modu: iki dokunuşla bağlar, kart sürüklenmez', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 800, 0, no: 2)], linkMode: true);
      await t.tapAt(screen(t, 100, 100));
      await t.pump();
      await t.tapAt(screen(t, 900, 100));
      await t.pump();
      expect(connects, [('a', 'b')]);
      expect(opens, isEmpty);
      await t.dragFrom(screen(t, 100, 100), const Offset(60, 40));
      expect(changes, isEmpty);
    });

    testWidgets('bağlantıya dokununca menü olayı gelir', (t) async {
      final l = _link('l1', 'a', 'b', label: 'neden');
      await pump(t, [_card('a', 0, 0), _card('b', 1000, 0, no: 2)], links: [l]);
      final mid = curveBetween(const BoardRect(0, 0, 320, 420), const BoardRect(1000, 0, 320, 420)).at(0.5);
      await t.tapAt(screen(t, mid.x, mid.y));
      await t.pump();
      expect(linkTaps.map((e) => e.id), ['l1']);
    });

    testWidgets('fare tekerleği zumu %2..%400 aralığında kalır; sığdır tüm kartları gösterir', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 9000, 6000, no: 2)]);
      expect(ctl.viewport.value.scale, lessThan(0.2));
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(const Offset(500, 400)));
      await t.sendEventToBinding(p.scroll(const Offset(0, -100000)));
      await t.pump();
      expect(ctl.viewport.value.scale, boardMaxScale);
      await t.sendEventToBinding(p.scroll(const Offset(0, 100000)));
      await t.pump();
      expect(ctl.viewport.value.scale, boardMinScale);
      ctl.fit();
      await t.pump();
      final vis = ctl.viewport.value.visibleRect(1000, 800);
      expect(vis.overlaps(const BoardRect(0, 0, 320, 420)), isTrue);
      expect(vis.right >= 9320 && vis.bottom >= 6420, isTrue);
    });

    testWidgets('150 kart: yalnız görünür kartlar çizilir; düşük ayrıntıda başlık+renk', (t) async {
      final cards = [for (var i = 0; i < 150; i++) _card('p$i', (i % 15) * 400.0, (i ~/ 15) * 500.0, no: i + 1)];
      await pump(t, cards);
      final st = t.state<BoardCanvasState>(find.byType(BoardCanvas));
      // Sığdırınca hepsi görünür (ölçek küçük): düşük ayrıntı.
      expect(ctl.viewport.value.scale, lessThan(boardLowDetailScale));
      expect(find.byType(BoardCardView), findsNWidgets(150));
      // Yakınlaş: yalnız birkaçı.
      final p = TestPointer(1, PointerDeviceKind.mouse);
      await t.sendEventToBinding(p.hover(const Offset(10, 10)));
      await t.sendEventToBinding(p.scroll(const Offset(0, -100000)));
      await t.pump();
      expect(st.visibleIds.length, lessThan(10));
      expect(find.byType(BoardCardView).evaluate().length, lessThan(10));
    });

    testWidgets('arama: eşleşmeyen kartlar soluk', (t) async {
      await pump(t, [_card('a', 0, 0, title: 'Türev'), _card('b', 800, 0, no: 2, title: 'İntegral')], query: 'türev');
      final views = t.widgetList<BoardCardView>(find.byType(BoardCardView)).toList();
      expect(views.where((v) => v.matched).map((v) => v.card.pageId), ['a']);
      expect(views.where((v) => v.dimmed).map((v) => v.card.pageId), ['b']);
    });

    testWidgets('konu rozeti ve alt sayfa işareti görünür', (t) async {
      await pump(t, [_card('a', 0, 0, konu: 'k1'), _card('b', 800, 0, no: 2, parent: 'a')]);
      ctl.viewport.value = const BoardViewport(scale: 0.5);
      await t.pump();
      expect(find.byKey(const Key('board-konu-badge')), findsOneWidget);
      expect(find.byIcon(Icons.subdirectory_arrow_right), findsOneWidget);
      expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    });

    testWidgets('telefon boyutunda taşma yok', (t) async {
      await pump(t, [_card('a', 0, 0), _card('b', 800, 0, no: 2)], links: [_link('l', 'a', 'b', label: 'x')], size: const Size(360, 640));
      expect(t.takeException(), isNull);
    });
  });

  group('ekran (veritabanı)', () {
    late AppDatabase db;
    late InkNotebookRepository nbRepo;
    late InkBoardRepository board;
    late String nb;
    late List<String> pageIds;

    Future<void> setup(WidgetTester t, {bool place = true}) async {
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        await db.customSelect('SELECT 1').get();
        nbRepo = InkNotebookRepository(db);
        board = InkBoardRepository(db, notebooks: nbRepo);
        nb = await nbRepo.createNotebook(title: 'Fizik');
        await nbRepo.addPage(nb);
        await nbRepo.addPage(nb);
        pageIds = [for (final p in await nbRepo.pages(nb)) p.id];
        if (place) {
          await board.setBoardPositions({
            pageIds[0]: const BoardRect(0, 0, 320, 420),
            pageIds[1]: const BoardRect(800, 0, 320, 420),
            pageIds[2]: const BoardRect(1600, 0, 320, 420),
          });
        }
      });
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 5));
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.runAsync(db.close);
      });
      final router = GoRouter(routes: [
        GoRoute(path: '/', builder: (_, __) => InkBoardScreen(notebookId: nb)),
        GoRoute(path: '/defter/:id', builder: (_, s) => Text('editor:${s.uri.queryParameters['sayfa']}')),
      ]);
      await t.pumpWidget(ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp.router(routerConfig: router),
      ));
      await wait(t);
    }

    BoardViewController ctlOf(WidgetTester t) => t.widget<BoardCanvas>(find.byType(BoardCanvas)).controller;

    Offset at(WidgetTester t, double wx, double wy) {
      final s = ctlOf(t).viewport.value.toScreen(wx, wy);
      return t.getTopLeft(find.byKey(const Key('board-canvas'))) + Offset(s.x, s.y);
    }

    Future<List<BoardCard>> cardsNow(WidgetTester t) => run(t, () => board.boardCards(nb));

    testWidgets('kart sürükleme setBoardPositions yazar; Geri al eski yere döndürür', (t) async {
      await setup(t);
      await t.dragFrom(at(t, 100, 100), const Offset(80, 0));
      await wait(t);
      var cs = await cardsNow(t);
      expect(cs.first.x, greaterThan(50));
      expect(find.text('Kart güncellendi'), findsOneWidget);
      await t.tap(find.text('Geri al'));
      await wait(t);
      cs = await cardsNow(t);
      expect(cs.first.x, 0);
    });

    testWidgets('bağlantı kurma, etiket, renk, silme ve geri alma', (t) async {
      await setup(t);
      final from = at(t, 320, 210), to = at(t, 900, 200);
      await t.dragFrom(from, to - from);
      await wait(t);
      var ls = await run(t, () => board.links(nb));
      expect(ls, hasLength(1));
      expect(ls.single.fromPageId, pageIds[0]);
      expect(ls.single.toPageId, pageIds[1]);

      final c = curveBetween(const BoardRect(0, 0, 320, 420), const BoardRect(800, 0, 320, 420)).at(0.5);
      await t.tapAt(at(t, c.x, c.y));
      await wait(t);
      await t.tap(find.byKey(const Key('link-label')));
      await wait(t);
      await t.enterText(find.byKey(const Key('link-label-field')), 'sebep');
      await t.tap(find.byKey(const Key('link-label-ok')));
      await wait(t);
      ls = await run(t, () => board.links(nb));
      expect(ls.single.label, 'sebep');

      await t.tapAt(at(t, c.x, c.y));
      await wait(t);
      await t.tap(find.byKey(const Key('link-color')));
      await wait(t);
      await t.tap(find.byKey(Key('link-color-${boardLinkColors[1]}')));
      await wait(t);
      ls = await run(t, () => board.links(nb));
      expect(ls.single.color, boardLinkColors[1]);

      await t.tapAt(at(t, c.x, c.y));
      await wait(t);
      await t.tap(find.byKey(const Key('link-delete')));
      await wait(t);
      expect(await run(t, () => board.links(nb)), isEmpty);
      await t.tap(find.text('Geri al'));
      await wait(t);
      expect(await run(t, () => board.links(nb)), hasLength(1));
    });

    testWidgets('boşluğa bırakınca yeni sayfa oluşturup bağlar', (t) async {
      await setup(t);
      final from = at(t, 320, 210), to = at(t, 900, 700);
      await t.dragFrom(from, to - from);
      await wait(t);
      await t.tap(find.byKey(const Key('board-create-child')));
      await wait(t, 12);
      final cs = await cardsNow(t);
      expect(cs, hasLength(4));
      final child = cs.firstWhere((c) => c.parentPageId == pageIds[0]);
      expect(child.x, closeTo(900 - 160, 5));
      final ls = await run(t, () => board.links(nb));
      expect(ls.where((l) => l.kind == PageLinkKind.child), hasLength(1));
    });

    testWidgets('otomatik düzenle onay ister; onayla yerleşir, Geri al döndürür', (t) async {
      await setup(t);
      await t.runAsync(() => board.setBoardPositions({pageIds[0]: const BoardRect(5000, 5000, 320, 420)}));
      await wait(t);
      await t.tap(find.byKey(const Key('board-arrange')));
      await wait(t);
      // Vazgeç: değişmez.
      await t.tap(find.text('Vazgeç'));
      await wait(t);
      expect((await cardsNow(t)).first.x, 5000);
      await t.tap(find.byKey(const Key('board-arrange')));
      await wait(t);
      await t.tap(find.byKey(const Key('board-arrange-ok')));
      await wait(t, 12);
      expect((await cardsNow(t)).first.x, isNot(5000));
      await t.tap(find.text('Geri al'));
      await wait(t);
      expect((await cardsNow(t)).first.x, 5000);
    });

    testWidgets('yeni sayfa kart olarak eklenir; yerleşmemişler açılışta yerleştirilir', (t) async {
      await setup(t, place: false);
      var cs = await cardsNow(t);
      expect(cs.every((c) => c.placed), isTrue);
      await t.tap(find.byKey(const Key('board-new')));
      await wait(t, 12);
      cs = await cardsNow(t);
      expect(cs, hasLength(4));
      expect(cs.every((c) => c.placed), isTrue);
    });

    testWidgets('karta dokununca sayfa editörüne gider', (t) async {
      await setup(t);
      await t.tapAt(at(t, 100, 100));
      await wait(t);
      expect(find.text('editor:${pageIds[0]}'), findsOneWidget);
    });

    testWidgets('araç çubuğu: yakınlaştırma yüzdesi görünür', (t) async {
      await setup(t);
      expect(find.byKey(const Key('board-zoom')), findsOneWidget);
      expect(find.textContaining('%'), findsWidgets);
    });
  });
}

Future<T> run<T>(WidgetTester t, Future<T> Function() f) async => (await t.runAsync(f)) as T;

Future<void> wait(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}
