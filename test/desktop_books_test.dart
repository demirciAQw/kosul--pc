import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/entry/book_tree_edit.dart';
import 'package:kocum/desktop/entry/books_page.dart';
import 'package:kocum/features/library/domain/library.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'b${_n++}';
}

ContentNode _n(String id, {List<ContentNode> kids = const [], int? q}) =>
    ContentNode(id: id, level: NodeLevel.topic, title: id, questionCount: q, children: kids);

void main() {
  group('ağaç düzenleme (saf)', () {
    final tree = [
      _n('a', kids: [_n('a1', q: 10), _n('a2', q: 12)]),
      _n('b'),
    ];

    test('altına ekleme seviyeyi derinlikten alır; kimlikler korunur', () {
      final r = addChildTo(tree, 'a1', _n('x', q: 5));
      final x = r.first.children.first.children.single;
      expect((x.id, x.level), ('x', NodeLevel.subtopic));
      final top = addChildTo(tree, null, _n('c'));
      expect((top.last.id, top.last.level), ('c', NodeLevel.unit));
      expect(top.first.children.map((n) => n.id), ['a1', 'a2']);
    });

    test('yeniden sıralama kardeşler arasında; sınırda aynı kalır', () {
      expect(moveNode(tree, 'a2', -1).first.children.map((n) => n.id), ['a2', 'a1']);
      expect(moveNode(tree, 'a1', -1).first.children.map((n) => n.id), ['a1', 'a2']);
      expect(moveNode(tree, 'a', 1).map((n) => n.id), ['b', 'a']);
      expect(moveNode(tree, 'b', 1).map((n) => n.id), ['a', 'b']);
    });

    test('düzenleme ve silme; altındakilerin kimlikleri', () {
      final e = replaceNode(tree, 'a2', (n) => editNode(n, title: 'Yeni', questionCount: 20, pageStart: 3, pageEnd: 9));
      final a2 = e.first.children.last;
      expect((a2.id, a2.title, a2.questionCount, a2.pageStart, a2.pageEnd), ('a2', 'Yeni', 20, 3, 9));
      final cleared = replaceNode(e, 'a2', (n) => editNode(n, clearQuestionCount: true, clearPages: true));
      expect((cleared.first.children.last.questionCount, cleared.first.children.last.hasPages), (null, false));
      expect(removeNodeFrom(tree, 'a').map((n) => n.id), ['b']);
      expect(removeNodeFrom(tree, 'a1').first.children.map((n) => n.id), ['a2']);
      expect(idsUnder(tree.first), {'a', 'a1', 'a2'});
    });
  });

  group('Kitaplar sayfası', () {
    late AppDatabase db;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      db = AppDatabase(NativeDatabase.memory(), 'pc');
      final c = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        idGeneratorProvider.overrideWithValue(_Ids()),
        clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 10)),
      ]);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: DesktopBooksPage())),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('boş durum; elle kitap, ünite, test ekle; sonuç gir; sil', (tester) async {
      await pump(tester);
      expect(find.textContaining('Henüz kitap yok'), findsOneWidget);

      // Elle kitap.
      await tester.tap(find.byKey(const ValueKey('kitap-ekle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elle yeni kitap'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kitap-olustur')));
      await tester.pump();
      expect(find.text('Ad, ders ve sayfa sayısı gerekli'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('kitap-ad')), '345 Matematik');
      await tester.tap(find.byKey(const ValueKey('ders:TYT')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Matematik').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kitap-olustur')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect((await db.select(db.books).get()).single.title, '345 Matematik');
      expect(find.text('Henüz bölüm yok.'), findsOneWidget);

      // Ünite → test.
      await tester.tap(find.byKey(const ValueKey('unite-ekle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('dugum-ad')), 'Türev');
      await tester.tap(find.byKey(const ValueKey('dugum-kaydet')));
      await settle(tester);
      await tester.pumpAndSettle();
      final unit = (await db.select(db.contentNodes).get()).single;
      expect((unit.title, unit.level), ('Türev', 'unit'));

      await tester.tap(find.byKey(ValueKey('alt-ekle:${unit.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('dugum-ad')), 'Test 1');
      await tester.enterText(find.byKey(const ValueKey('dugum-soru')), '15');
      await tester.tap(find.byKey(const ValueKey('dugum-kaydet')));
      await settle(tester);
      await tester.pumpAndSettle();
      final nodes = await db.select(db.contentNodes).get();
      final test = nodes.firstWhere((n) => n.title == 'Test 1');
      expect((test.questionCount, test.parentId), (15, unit.id));

      // Sonuç gir.
      await tester.tap(find.byKey(ValueKey('menu:${test.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sonuç gir (D/Y/B)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('sonuc-d')), '10');
      await tester.enterText(find.byKey(const ValueKey('sonuc-y')), '3');
      await tester.enterText(find.byKey(const ValueKey('sonuc-b')), '2');
      await tester.tap(find.byKey(const ValueKey('sonuc-kaydet')));
      await settle(tester);
      await tester.pumpAndSettle();
      final res = (await db.select(db.testResults).get()).single;
      expect((res.correct, res.wrong, res.blank), (10, 3, 2));
      expect(find.text('10D 3Y 2B'), findsOneWidget);

      // Silme onaylı; soru bu başlıktan ayrılır, silinmez.
      await db.customStatement(
          "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at, content_node_id) "
          "VALUES ('q', 'wrong', 'book', 'x', 'TYT Matematik', 3, '', 1760000000, '${test.id}')");
      await tester.tap(find.byKey(ValueKey('menu:${test.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sil').last);
      await tester.pumpAndSettle();
      expect(find.text('Başlık silinsin mi?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dugum-sil-onay')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect((await db.select(db.contentNodes).get()).map((n) => n.title), ['Türev']);
      final card = (await db.select(db.questionCards).get()).single;
      expect(card.contentNodeId, isNull);
    });
  });
}
