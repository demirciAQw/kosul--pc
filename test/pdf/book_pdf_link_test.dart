import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kocum/app/routes.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/library/presentation/book_detail_screen.dart';
import 'package:kocum/features/library/presentation/books_screen.dart';
import 'package:kocum/features/pdf/data/pdf_document_repository.dart';

const _sha = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';

void main() {
  late AppDatabase db;
  late String opened;

  Future<void> pump(WidgetTester t, {required bool linked, String start = AppRoutes.books}) async {
    t.view.physicalSize = const Size(900, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    opened = '';
    await t.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      for (final (id, title) in [('k1', 'PDF Kitabı'), ('k2', 'PDF Olmayan')]) {
        await db.into(db.books).insert(BooksCompanion.insert(
              id: id,
              title: title,
              examType: 'TYT',
              subject: 'Fizik',
              pageCount: 100,
              avgQuestionsPerPage: 1,
              createdAt: DateTime(2026),
            ));
      }
      final repo = PdfDocumentRepository(db);
      await repo.add(sha256: _sha.substring(0, 64), title: 'Fizik PDF', pageCount: 50, fileName: 'f.pdf');
      if (linked) await repo.linkBook(_sha.substring(0, 64), 'k1');
    });
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.runAsync(() => db.close());
    });
    final router = GoRouter(initialLocation: start, routes: [
      GoRoute(path: AppRoutes.books, builder: (_, _) => const BooksScreen()),
      GoRoute(path: '/books/:id', builder: (_, s) => BookDetailScreen(bookId: s.pathParameters['id']!)),
      GoRoute(
        path: '/pdf/:id',
        builder: (_, s) {
          opened = s.pathParameters['id']!;
          return Text('okuyucu ${s.pathParameters['id']}');
        },
      ),
      GoRoute(path: '/', builder: (_, _) => const SizedBox()),
    ]);
    await t.pumpWidget(ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: MaterialApp.router(routerConfig: router),
    ));
    for (var i = 0; i < 6; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
      await t.pump();
    }
  }

  testWidgets('kitap kapağında PDF rozeti yalnız PDF bağlıysa; uzun basınca "PDF\'te aç"', (t) async {
    await pump(t, linked: true);
    // Bir rozet: PDF'i olan kitapta.
    expect(find.text('PDF'), findsOneWidget);
    await t.longPress(find.text('PDF Olmayan'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('book-open-pdf')), findsNothing); // PDF'siz kitapta menü yok
    await t.longPress(find.text('PDF Kitabı'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('book-open-pdf')));
    await t.pumpAndSettle();
    expect(opened, _sha.substring(0, 64));
    expect(find.textContaining('okuyucu'), findsOneWidget);
  });

  testWidgets('PDF bağlı değilse rozet de menü de yok', (t) async {
    await pump(t, linked: false);
    expect(find.text('PDF'), findsNothing);
    await t.longPress(find.text('PDF Kitabı'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('book-open-pdf')), findsNothing);
  });

  testWidgets('kitap ayrıntısında "PDF\'te aç" düğmesi bağlıysa çıkar ve okuyucuyu açar', (t) async {
    await pump(t, linked: true, start: '/books/k1');
    await t.tap(find.byKey(const Key('book-detail-open-pdf')));
    await t.pumpAndSettle();
    expect(opened, _sha.substring(0, 64));
  });

  testWidgets('kitap ayrıntısında PDF bağlı değilse düğme yok', (t) async {
    await pump(t, linked: false, start: '/books/k1');
    expect(find.byKey(const Key('book-detail-open-pdf')), findsNothing);
    expect(find.text('PDF Kitabı'), findsWidgets);
  });
}
