import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/features/ledger/domain/change_view.dart';
import 'package:kocum/features/ledger/presentation/ledger_views.dart';

LedgerChange _c(String id, String op, {String? old, String? neu, String? session, String source = 'claude', String clock = '0001760000000-0000-d'}) =>
    LedgerChange(id: id, device: 'd', source: source, session: session, table: 'anlik_notes', rowId: 'r', op: op, old: old, neu: neu, clock: clock);

void main() {
  group('değişiklik açıklaması', () {
    test('ekleme, silme ve değişen alan', () {
      expect(describeChange(_c('1', 'ekle', neu: '{"body":"  Kantinde   işlem yaptım "}')).title, 'Anlık not eklendi');
      expect(describeChange(_c('1', 'ekle', neu: '{"body":"Kantinde işlem"}')).detail, 'Kantinde işlem');
      expect(describeChange(_c('2', 'sil', old: '{"body":"eski metin"}')).title, 'Anlık not silindi');
      expect(describeChange(_c('3', 'degistir', old: '{"body":"a","mood":1}', neu: '{"body":"b","mood":1}')).detail, 'b');
      expect(describeChange(_c('4', 'degistir', old: '{"mood":1,"x":1}', neu: '{"mood":2,"x":1}')).detail, 'mood');
      expect(describeChange(_c('5', 'ekle', neu: 'bozuk json')).detail, '');
      expect(describeChange(_c('6', 'ekle', neu: '{"body":"${'x' * 200}"}')).detail.length, lessThanOrEqualTo(81));
    });

    test('oturumlara gruplanır, yalnızca Claude, sıra korunur', () {
      final g = groupBySession([
        _c('a', 'ekle', session: 'o2'),
        _c('b', 'ekle', session: 'o1'),
        _c('c', 'ekle', session: 'o2'),
        _c('d', 'ekle', session: 'o1', source: 'pc'),
        _c('e', 'ekle'),
      ]);
      expect([for (final x in g) x.session], ['o2', 'o1', null]);
      expect([for (final c in g.first.changes) c.id], ['a', 'c']);
      expect(g[1].changes.length, 1); // pc'nin kendi değişikliği Claude'unki sayılmaz
      expect(changeTime(_c('x', 'ekle')).millisecondsSinceEpoch, 1760000000);
    });
  });

  group('ekranlar', () {
    late AppDatabase db;
    late LedgerService ledger;
    late ProviderContainer c;

    Future<void> pump(WidgetTester tester, Widget view) async {
      db = AppDatabase(NativeDatabase.memory(), 'pc');
      ledger = LedgerService(db);
      await db.customSelect('SELECT 1').get();
      c = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.runAsync(db.close);
      });
      await tester.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: Scaffold(body: view))));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      await tester.pump();
    }

    Future<void> note(String id, String body) => db.into(db.anlikNotes).insert(AnlikNotesCompanion.insert(
        id: id, createdAt: DateTime(2026), updatedAt: DateTime(2026), body: body, searchText: Value(body)));

    testWidgets('Claude değişiklikleri: boş durum, madde geri al, oturumu geri al', (tester) async {
      await pump(tester, const ClaudeChangesView());
      expect(find.textContaining('Claude henüz bir şey değiştirmedi'), findsOneWidget);

      await tester.runAsync(() => ledger.withSource('claude', session: 'oturumABCDEFGH', body: () async {
            await note('a', 'birinci not');
            await note('b', 'ikinci not');
          }));
      await settle(tester);
      expect(find.textContaining('Oturum oturumAB'), findsOneWidget);
      expect(find.text('Anlık not eklendi'), findsNWidgets(2));

      // Bir maddeyi geri al.
      await tester.tap(find.text('Geri al').first);
      await settle(tester);
      await settle(tester);
      expect((await db.select(db.anlikNotes).get()).length, 1);
      expect(find.text('geri alındı'), findsOneWidget);

      // Oturumu geri al: kalan da gider.
      await tester.tap(find.byKey(const ValueKey('oturumu-geri-al:oturumABCDEFGH')));
      await settle(tester);
      await settle(tester);
      expect(await db.select(db.anlikNotes).get(), isEmpty);
    });

    testWidgets('Çakışmalar: kaybeden sürüm geri getirilir ve çakışma kapanır', (tester) async {
      await pump(tester, const ConflictsView());
      expect(find.textContaining('Çakışma yok'), findsOneWidget);

      await note('n', 'kazanan metin');
      await db.into(db.cakismalar).insert(CakismalarCompanion.insert(
            id: 'k1',
            tablo: 'anlik_notes',
            satirId: 'n',
            kazanan: const Value('{"id":"n","created_at":1767225600,"updated_at":1767225600,"body":"kazanan metin","kind":"anlik","mood":null,"search_text":"kazanan metin","subject":null,"meb_node_id":null,"topic_text":null}'),
            kaybeden: const Value('{"id":"n","created_at":1767225600,"updated_at":1767225600,"body":"kaybeden metin","kind":"anlik","mood":null,"search_text":"kaybeden metin","subject":null,"meb_node_id":null,"topic_text":null}'),
            taraf: 'uzak',
            saat: '0001760000000-0000-d',
            createdAt: DateTime(2026, 10, 20),
          ));
      await settle(tester);
      expect(find.textContaining('Kaybeden: kaybeden metin'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cakisma-geri:k1')));
      await settle(tester);
      await settle(tester);
      expect((await db.select(db.anlikNotes).get()).single.body, 'kaybeden metin');
      expect(find.textContaining('Çakışma yok'), findsOneWidget);
    });
  });
}
