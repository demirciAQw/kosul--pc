import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/anlik/notes_page.dart';
import 'package:kocum/features/anlik/presentation/widgets/card_links.dart';
import 'package:kocum/desktop/anlik/people_page.dart';

class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'd${_n++}';
}

Future<AppDatabase> _pump(WidgetTester tester, Widget page, {Size size = const Size(1200, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase(NativeDatabase.memory());
  final c = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    idGeneratorProvider.overrideWithValue(_Ids()),
    clockProvider.overrideWithValue(() => DateTime(2026, 10, 20, 8, 30)),
  ]);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: Scaffold(body: page))));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
  return db;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pump();
  await tester.pump();
}

void main() {
  _cardTests();
  testWidgets('Notlar: boş durum, Ctrl+N yeni not, Ctrl+S kaydeder, liste güncellenir, Geri al çalışır', (tester) async {
    final db = await _pump(tester, const DesktopNotesPage());
    expect(find.textContaining('Henüz not yok'), findsOneWidget);
    expect(find.byKey(const ValueKey('anlik-yazi')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.byKey(const ValueKey('anlik-yazi')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('anlik-yazi')), 'Masaüstünden yazdım');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await _settle(tester);
    expect((await db.select(db.anlikNotes).get()).single.body, 'Masaüstünden yazdım');
    expect(find.text('Masaüstünden yazdım'), findsWidgets); // listede
    expect(find.text('Geri al'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 600)); // SnackBar yerine otursun
    await tester.tap(find.text('Geri al'));
    await _settle(tester);
    expect(await db.select(db.anlikNotes).get(), isEmpty);
  });

  testWidgets('Notlar: Esc paneli kapatır; Ctrl+F aramaya odaklanır ve aranan süzülür', (tester) async {
    final db = await _pump(tester, const DesktopNotesPage());
    for (final (i, body) in ['elma armut', 'kiraz vişne'].indexed) {
      await db.into(db.anlikNotes).insert(AnlikNotesCompanion.insert(
            id: 'n$i',
            createdAt: DateTime(2026, 10, 1 + i),
            updatedAt: DateTime(2026, 10, 1 + i),
            body: body,
            searchText: Value(body),
          ));
    }
    await _settle(tester);
    await tester.tap(find.text('elma armut'));
    await tester.pump();
    expect(find.byKey(const ValueKey('anlik-yazi')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('anlik-yazi'))).controller!.text, 'elma armut');

    // Başka nota geçince editör o notun metniyle açılır.
    await tester.tap(find.text('kiraz vişne').first);
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('anlik-yazi'))).controller!.text, 'kiraz vişne');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('anlik-yazi')), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('anlik-ara')), 'ELMA');
    await tester.pump();
    expect(find.text('kiraz vişne'), findsNothing);
    expect(find.text('elma armut'), findsOneWidget);
  });

  testWidgets('Notlar: dar pencerede düzen bozulmaz (liste, sonra not)', (tester) async {
    await _pump(tester, const DesktopNotesPage(), size: const Size(500, 700));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('anlik-ara')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('not-yeni')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('anlik-yazi')), findsOneWidget);
    expect(find.text('Liste'), findsOneWidget);
  });

  testWidgets('Kişiler: ekle, takma ad, kişiye tıklayınca notları', (tester) async {
    final db = await _pump(tester, const DesktopPeoplePage());
    await tester.tap(find.byKey(const ValueKey('kisi-yeni')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('kisi-ad')), 'Şule');
    await tester.enterText(find.byKey(const ValueKey('kisi-takma')), 'Şulo');
    await tester.tap(find.byKey(const ValueKey('kisi-kaydet')));
    await tester.pumpAndSettle();
    await _settle(tester);
    expect((await db.select(db.people).get()).single.aliases, ['Şulo']);

    await db.into(db.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: 'n', createdAt: DateTime(2026, 10, 1), updatedAt: DateTime(2026, 10, 1), body: 'Şule ile konuştum'));
    await db.into(db.anlikNotePeople).insert(AnlikNotePeopleCompanion.insert(id: 'n:d0', noteId: 'n', personId: 'd0'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('kisi-satir:d0')));
    await tester.pump();
    expect(find.text('Şule hakkında'), findsOneWidget);
    expect(find.text('Şule ile konuştum'), findsOneWidget);
  });
}

void _cardTests() {
  testWidgets('Defter: soruya etiket eklenir, soruya not yazılıp bağlanır', (tester) async {
    final db = await _pump(tester, const SingleChildScrollView(child: CardTagsSection(cardId: 'c1')));
    await db.into(db.questionCards).insert(QuestionCardsCompanion.insert(
          id: 'c1',
          status: 'wrong',
          origin: 'independent',
          sourceName: 'x',
          subject: 'TYT Matematik',
          difficulty: 3,
          searchText: '',
          createdAt: DateTime(2026),
        ));
    await tester.tap(find.byKey(const ValueKey('etiket-ekle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('etiket-ara')), 'dikkatsizlik');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('etiket-olustur')));
    await tester.pumpAndSettle();
    await _settle(tester);
    // Oluşturulan etiket seçilir ve karta bağlanır.
    expect((await db.select(db.questionCardTags).get()).single.cardId, 'c1');
    expect((await db.select(db.tags).get()).single.label, 'dikkatsizlik');
  });
}
