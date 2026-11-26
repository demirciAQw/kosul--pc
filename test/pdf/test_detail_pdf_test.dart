import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/routes.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/library/data/library_data.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/library/presentation/book_detail_screen.dart';
import 'package:kocum/features/library/presentation/test_detail_screen.dart';
import 'package:kocum/features/pdf/data/pdf_document_repository.dart';

final _sha = 'f' * 64;

void main() {
  late AppDatabase db;
  late String opened;

  Future<void> pump(WidgetTester t, {required bool linked, int offset = 0, String start = '/books/k/tests/t2'}) async {
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    opened = '';
    await t.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      await DriftLibraryRepository(db).save(Book(
        id: 'k',
        title: 'K',
        examType: 'TYT',
        subject: 'Fizik',
        pageCount: 100,
        avgQuestionsPerPage: 1,
        createdAt: DateTime(2026),
        roots: const [
          ContentNode(id: 't1', level: NodeLevel.unit, title: 'Test 1', pageStart: 1, pageEnd: 9, questionCount: 5),
          ContentNode(id: 't2', level: NodeLevel.unit, title: 'Test 2', pageStart: 10, pageEnd: 19, questionCount: 5),
          ContentNode(id: 't3', level: NodeLevel.unit, title: 'Test 3', questionCount: 5),
        ],
      ));
      final repo = PdfDocumentRepository(db);
      await repo.add(sha256: _sha, title: 'K PDF', pageCount: 60, fileName: 'k.pdf');
      if (linked) await repo.linkBook(_sha, 'k');
      await repo.setOffset(_sha, offset);
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.runAsync(() => db.close());
    });
    final router = GoRouter(initialLocation: start, routes: [
      GoRoute(path: '/books/:id', builder: (_, s) => BookDetailScreen(bookId: s.pathParameters['id']!)),
      GoRoute(
        path: '/books/:id/tests/:node',
        builder: (_, s) => TestDetailScreen(bookId: s.pathParameters['id']!, nodeId: s.pathParameters['node']!),
      ),
      GoRoute(
        path: '/pdf/:id',
        builder: (_, s) {
          opened = s.uri.toString();
          return Text('okuyucu');
        },
      ),
    ]);
    addTearDown(router.dispose);
    await t.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp.router(routerConfig: router),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
      await t.pump();
    }
  }

  testWidgets("test ayrıntısı: PDF'te aç testin sayfasına (ofsetli) atlar; analiz düğmesi analiz=1 ekler", (t) async {
    await pump(t, linked: true, offset: 2);
    expect(AppRoutes.bookTest('k', 't2'), '/books/k/tests/t2');
    await t.tap(find.byKey(const Key('test-open-pdf')));
    await t.pumpAndSettle();
    expect(opened, '/pdf/$_sha?page=7'); // 10 - 1 - 2
  });

  testWidgets('test ayrıntısı: analiz modunda aç', (t) async {
    await pump(t, linked: true);
    await t.tap(find.byKey(const Key('test-open-pdf-analysis')));
    await t.pumpAndSettle();
    expect(opened, '/pdf/$_sha?page=9&analiz=1');
  });

  testWidgets('sayfası bilinmeyen testte PDF düğmesi yok', (t) async {
    await pump(t, linked: true, start: '/books/k/tests/t3');
    expect(find.byKey(const Key('test-open-pdf')), findsNothing);
  });

  testWidgets('PDF bağlı değilse test ayrıntısında düğme yok (eski davranış)', (t) async {
    await pump(t, linked: false);
    expect(find.byKey(const Key('test-open-pdf')), findsNothing);
    expect(find.byKey(const Key('test-open-pdf-analysis')), findsNothing);
    expect(find.text('Optikle işaretle'), findsOneWidget);
  });

  testWidgets('kitap ayrıntısı: "PDF\'te analiz modunda aç" analiz=1 ile açar; PDF yoksa yok', (t) async {
    await pump(t, linked: true, start: '/books/k');
    await t.tap(find.byKey(const Key('book-detail-open-pdf-analysis')));
    await t.pumpAndSettle();
    expect(opened, '/pdf/$_sha?analiz=1');
  });

  testWidgets('kitap ayrıntısı, PDF yok: analiz düğmesi yok', (t) async {
    await pump(t, linked: false, start: '/books/k');
    expect(find.byKey(const Key('book-detail-open-pdf-analysis')), findsNothing);
    expect(find.byKey(const Key('book-detail-open-pdf')), findsNothing);
  });
}
