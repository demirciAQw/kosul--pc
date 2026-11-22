import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/pdf/data/pdf_import_service.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/pdf_providers.dart';
import 'package:kocum/features/pdf/presentation/pdf_library_page.dart';

import 'pdf_test_support.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late File pick;
  late List<PdfDocumentRecord> opened;
  late List<File?> picks;

  Future<void> pump(WidgetTester t) async {
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('pdf_kitaplik');
      pick = File('${tmp.path}/Tyt Matematik Soru Bankasi.pdf')
        ..writeAsBytesSync(FakePdfEngine.bytes(7));
      db = AppDatabase(NativeDatabase.memory());
      await db.customSelect('SELECT 1').get();
    });
    addTearDown(() async {
      // Önce ağacı söküp akışları bırak; açık akışlar varken veritabanı kapanmaz.
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });
    opened = [];
    picks = [pick];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          pdfEngineProvider.overrideWithValue(FakePdfEngine()),
          pdfImportServiceProvider.overrideWith(
            (ref) async => PdfImportService(
              engine: ref.watch(pdfEngineProvider),
              repository: ref.watch(pdfDocumentRepositoryProvider),
              pdfDir: Directory('${tmp.path}/pdfs'),
            ),
          ),
          pdfPickerProvider.overrideWithValue(
            () async => picks.isEmpty ? null : picks.removeAt(0),
          ),
        ],
        child: MaterialApp(
          home: PdfLibraryPage(onOpen: (_, d) => opened.add(d)),
        ),
      ),
    );
    await t.pump();
  }

  Future<void> wait(WidgetTester t) async {
    // Zincir hem gerçek G/Ç hem sahte zaman mikro görevleri içerir: dönüşümlü bekle.
    for (var i = 0; i < 8; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
      await t.pump();
    }
  }

  testWidgets(
    'boş liste; içe aktarınca listelenir (başlık, sayfa sayısı) ve açılır',
    (t) async {
      await pump(t);
      expect(find.textContaining('Henüz PDF yok'), findsOneWidget);
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      await wait(t);
      expect(find.textContaining('eklendi'), findsOneWidget);
      expect(find.text('Tyt Matematik Soru Bankasi'), findsOneWidget);
      expect(find.text('7 sayfa'), findsOneWidget);
      await t.tap(find.text('Tyt Matematik Soru Bankasi'));
      expect(opened.single.pageCount, 7);
      // Dosya veri klasörüne kopyalandı.
      expect(
        Directory('${tmp.path}/pdfs')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.pdf')),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'seçici iptal edilirse bir şey olmaz; aynı PDF ikinci kez eklenmez',
    (t) async {
      await pump(t);
      picks = [null, pick, pick];
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      expect(find.textContaining('Henüz PDF yok'), findsOneWidget);
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      await wait(t);
      ScaffoldMessenger.of(t.element(find.byType(Scaffold)))
          .clearSnackBars(); // ilk bildirim kapansın
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      await wait(t);
      expect(find.textContaining('zaten kitaplıkta'), findsOneWidget);
      expect(find.text('7 sayfa'), findsOneWidget);
    },
  );

  testWidgets('bozuk PDF: hata gösterilir, listeye girmez', (t) async {
    await pump(t);
    final bad = File('${tmp.path}/bozuk.pdf');
    await t.runAsync(() => bad.writeAsBytes([1, 2, 3]));
    picks = [bad];
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    await wait(t);
    expect(find.textContaining('PDF açılamadı'), findsOneWidget);
    expect(find.textContaining('Henüz PDF yok'), findsOneWidget);
  });

  testWidgets('kitap önerisi sorulur; yalnız onaylanırsa bağlanır', (t) async {
    await pump(t);
    await t.runAsync(
      () => db
          .into(db.books)
          .insert(
            BooksCompanion.insert(
              id: 'k1',
              title: 'TYT Matematik Soru Bankası',
              examType: 'TYT',
              subject: 'Matematik',
              pageCount: 100,
              avgQuestionsPerPage: 5,
              createdAt: DateTime(2026),
            ),
          ),
    );
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    await wait(t);
    expect(find.byKey(const Key('pdf-book-suggestion')), findsOneWidget);
    expect(find.textContaining('TYT Matematik Soru Bankası'), findsWidgets);
    // Hayır: bağlanmaz.
    await t.tap(find.text('Hayır'));
    await wait(t);
    var rec = (await t.runAsync(
      () =>
          ProviderScope.containerOf(t.element(find.byType(PdfLibraryPage)))
              .read(pdfDocumentRepositoryProvider)
              .list(),
    ))!;
    expect(rec.single.bookId, isNull);
    // Aynı PDF yeniden: bu kez evet.
    picks = [pick];
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    await wait(t);
    await t.tap(find.text('Bağla'));
    await wait(t);
    rec = (await t.runAsync(
      () =>
          ProviderScope.containerOf(t.element(find.byType(PdfLibraryPage)))
              .read(pdfDocumentRepositoryProvider)
              .list(),
    ))!;
    expect(rec.single.bookId, 'k1');
    expect(find.textContaining('kitaba bağlı'), findsOneWidget);
  });

  testWidgets(
    'listeden kaldırma onay ister; onaylanırsa yumuşak silinir, vazgeçilirse kalır',
    (t) async {
      await pump(t);
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      await wait(t);
      await t.tap(find.byType(PopupMenuButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('Listeden kaldır'));
      await t.pumpAndSettle();
      await t.tap(find.text('Vazgeç'));
      await wait(t);
      expect(find.text('Tyt Matematik Soru Bankasi'), findsOneWidget);
      await t.tap(find.byType(PopupMenuButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('Listeden kaldır'));
      await t.pumpAndSettle();
      await t.tap(find.text('Kaldır'));
      await wait(t);
      expect(find.text('Tyt Matematik Soru Bankasi'), findsNothing);
      // Satır ve dosya durur.
      final all = await t.runAsync(() => db.select(db.pdfDocuments).get());
      expect(all!.single.deleted, isTrue);
      expect(
        Directory('${tmp.path}/pdfs')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.pdf')),
        hasLength(1),
      );
    },
  );
}
