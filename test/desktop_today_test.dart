import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/desktop/desktop_providers.dart';
import 'package:kocum/desktop/entry/books_page.dart';
import 'package:kocum/desktop/notebook/notebook_providers.dart';
import 'package:kocum/desktop/today/domain/today_groups.dart';
import 'package:kocum/desktop/today/today_page.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_bank.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/question_bank/domain/srs.dart';

final _now = DateTime(2026, 10, 20, 10);

QuestionCard _card(String id, String subject, {String? topic}) => QuestionCard(
      id: id,
      status: QuestionStatus.wrong,
      origin: QuestionOrigin.independent,
      sourceName: 'Kitap $id',
      subject: subject,
      topicText: topic,
      difficulty: 5,
      createdAt: DateTime(2026, 10, 1),
    );

ReviewState _due(DateTime d) =>
    ReviewState(easeFactor: 2.5, intervalDays: 1, repetitions: 1, dueAt: d);

void main() {
  group('gruplama (saf)', () {
    test('ders ve konuya böler; çok olan önde; konu içinde en eski vade önde', () {
      final r = [
        DueReview(_card('a', 'TYT Fizik', topic: 'Kuvvet'), _due(DateTime(2026, 10, 19))),
        DueReview(_card('b', 'TYT Matematik', topic: 'Türev'), _due(DateTime(2026, 10, 20))),
        DueReview(_card('c', 'TYT Matematik', topic: 'Türev'), _due(DateTime(2026, 10, 15))),
        DueReview(_card('d', 'TYT Matematik'), _due(DateTime(2026, 10, 20))),
      ];
      final g = groupDueReviews(r, (x) => x.card.topicText);
      expect(g.map((s) => (s.subject, s.count)), [('TYT Matematik', 3), ('TYT Fizik', 1)]);
      expect(g.first.topics.map((t) => (t.title, t.count)), [('Türev', 2), (noTopicTitle, 1)]);
      expect(g.first.topics.first.reviews.map((x) => x.card.id), ['c', 'b']);
    });

    test('gecikme gün başına göre sayılır; gelecek 0', () {
      expect(overdueDays(DateTime(2026, 10, 20, 23), DateTime(2026, 10, 20, 1)), 0);
      expect(overdueDays(DateTime(2026, 10, 17, 23), DateTime(2026, 10, 20, 1)), 3);
      expect(overdueDays(DateTime(2026, 10, 25), DateTime(2026, 10, 20)), 0);
    });
  });

  group('Bugün sayfası', () {
    late AppDatabase db;
    late ProviderContainer c;

    Future<void> pump(WidgetTester tester, Widget page) async {
      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      db = AppDatabase(NativeDatabase.memory(), 'pc');
      c = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(() => _now),
      ]);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.runAsync(db.close);
      });
      await tester.runAsync(() async {
        final repo = DriftQuestionCardRepository(db);
        await repo.insert(_card('a', 'TYT Matematik', topic: 'Türev'), review: _due(DateTime(2026, 10, 18)));
        await repo.insert(_card('b', 'TYT Fizik', topic: 'Kuvvet'), review: _due(DateTime(2026, 10, 20)));
        await repo.insert(_card('z', 'TYT Kimya'), review: _due(DateTime(2026, 11, 30))); // gelecek
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(home: Scaffold(body: page)),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('bugünkü tekrarlar ders ve konuya göre listelenir; gelecek vadeli görünmez', (tester) async {
      await pump(tester, const DesktopTodayPage());
      expect(find.text('2 soru tekrar bekliyor · 2 ders'), findsOneWidget);
      expect(find.text('TYT Matematik'), findsOneWidget);
      expect(find.text('Türev'), findsOneWidget);
      expect(find.text('TYT Kimya'), findsNothing);
      expect(find.textContaining('2 gün gecikti'), findsOneWidget);
      expect(find.textContaining('bugün'), findsWidgets);
    });

    testWidgets('soruya basınca Defter açılır ve soru seçilir', (tester) async {
      await pump(tester, const DesktopTodayPage());
      c.read(desktopSectionProvider.notifier).select(DesktopSection.today);
      await tester.tap(find.byKey(const ValueKey('bugun-soru:a')));
      await tester.pump();
      expect(c.read(desktopSectionProvider), DesktopSection.notebook);
      expect(c.read(notebookSelectionProvider), 'a');
    });

    testWidgets('masaüstü açılışta Bugün bölümünde başlar', (tester) async {
      await pump(tester, const SizedBox());
      expect(c.read(desktopSectionProvider), DesktopSection.today);
    });

    testWidgets('Kitaplar: TYT, AYT ve MEB ayrı raflarda', (tester) async {
      await pump(tester, const DesktopBooksPage());
      await tester.runAsync(() async {
        final now = DateTime(2026, 10, 1);
        BooksCompanion book(String id, String title, String exam, String? publisher) => BooksCompanion.insert(
              id: id,
              title: title,
              examType: exam,
              subject: 'Matematik',
              pageCount: 100,
              avgQuestionsPerPage: 1.0,
              publisher: Value(publisher),
              createdAt: now,
            );
        await db.batch((b) => b.insertAll(db.books, [
              book('t1', 'TYT Kitabı', 'TYT', null),
              book('m1', 'MEB 11 Matematik', 'AYT', 'MEB'),
            ]));
      });
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
      await tester.pump();
      expect(find.text('TYT (1)'), findsOneWidget);
      expect(find.text('MEB (1)'), findsOneWidget);
      expect(find.text('TYT Kitabı'), findsOneWidget);
      expect(find.text('MEB 11 Matematik'), findsNothing);

      await tester.tap(find.text('MEB (1)'));
      await tester.pump();
      expect(find.text('MEB 11 Matematik'), findsOneWidget);
      expect(find.text('TYT Kitabı'), findsNothing);
    });
  });
}
