import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/di/core_providers.dart';
import 'package:kocum/features/library/presentation/library_sheet.dart' show BundledTemplate, bundledTemplatesProvider;
import 'package:kocum/features/ocr/auto_tag_providers.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/library/presentation/widgets/book_shelf_view.dart' show BookCoverFace;
import 'package:kocum/features/pdf/data/pdf_import_service.dart';
import 'package:kocum/features/pdf/presentation/pdf_book_flow.dart' show templateAssetLoaderProvider;
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
          // Test bağlamında asset yükleme takılabildiği için gerçek dosyalar doğrudan okunur.
          topicLexiconProvider.overrideWith(
            (ref) async => TopicLexicon.fromJson(
              jsonDecode(File('assets/meb/konu_sozlugu.json').readAsStringSync()) as Map<String, dynamic>,
            ),
          ),
          bundledTemplatesProvider.overrideWith(
            (ref) async => const [
              BundledTemplate(
                asset: 'assets/templates/BilgiSarmal_IlkAsama_Fizik.json',
                title: 'Bilgi Sarmal İlk Aşama Fizik Soru Bankası',
                subtitle: '',
                shelf: 'TYT',
              ),
            ],
          ),
          templateAssetLoaderProvider.overrideWithValue(
            (asset) async => File(asset).readAsStringSync(),
          ),
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

  /// Gerçek G/Ç ile sahte zamanı dönüşümlü ilerletir; [f] bulunana dek bekler.
  Future<void> until(WidgetTester t, Finder f) async {
    for (var i = 0; i < 150 && f.evaluate().isEmpty; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  /// İçe aktar'a bas, pencere açılınca (kutu işaretini ayarla) onayla.
  Future<void> importVia(WidgetTester t, {bool asBook = false}) async {
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    expect(find.byKey(const Key('pdf-import-dialog')), findsOneWidget);
    final box = t.widget<CheckboxListTile>(
      find.byKey(const Key('pdf-import-as-book')),
    );
    if (box.value != asBook) {
      await t.tap(find.byKey(const Key('pdf-import-as-book')));
      await t.pump();
    }
    await t.tap(find.byKey(const Key('pdf-import-confirm')));
    await wait(t);
    await wait(t);
    if (asBook) await until(t, find.byKey(const Key('book-save')));
  }

  testWidgets(
    'boş liste; içe aktarınca listelenir (başlık, sayfa sayısı) ve açılır',
    (t) async {
      await pump(t);
      expect(find.textContaining('Henüz PDF yok'), findsOneWidget);
      await importVia(t);
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
      await importVia(t);
      ScaffoldMessenger.of(t.element(find.byType(Scaffold)))
          .clearSnackBars(); // ilk bildirim kapansın
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const Key('pdf-import')));
      await wait(t);
      // Pencere "zaten var" der ve kitap kutusu çıkar.
      expect(find.byKey(const Key('pdf-import-exists')), findsOneWidget);
      await t.tap(find.byKey(const Key('pdf-import-as-book')));
      await t.pump();
      await t.tap(find.byKey(const Key('pdf-import-confirm')));
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
    expect(find.byKey(const Key('pdf-import-dialog')), findsNothing);
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
    await importVia(t);
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
    await importVia(t);
    await t.tap(find.text('Bağla'));
    await wait(t);
    rec = (await t.runAsync(
      () =>
          ProviderScope.containerOf(t.element(find.byType(PdfLibraryPage)))
              .read(pdfDocumentRepositoryProvider)
              .list(),
    ))!;
    expect(rec.single.bookId, 'k1');
    // Rafta bağlı kitabın adı kapakta görünür.
    expect(find.text('TYT Matematik Soru Bankası'), findsOneWidget);
  });

  testWidgets(
    'listeden kaldırma onay ister; onaylanırsa yumuşak silinir, vazgeçilirse kalır',
    (t) async {
      await pump(t);
      await importVia(t);
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

  Future<File> namedPick(WidgetTester t, String name) async {
    final f = File('${tmp.path}/$name');
    await t.runAsync(() => f.writeAsBytes(FakePdfEngine.bytes(7)));
    return f;
  }

  Future<List<PdfDocumentRow>> docs(WidgetTester t) async =>
      (await t.runAsync(() => db.select(db.pdfDocuments).get()))!;
  Future<List<BookRow>> bookRows(WidgetTester t) async =>
      (await t.runAsync(() => db.select(db.books).get()))!;

  void tall(WidgetTester t) {
    t.view.physicalSize = const Size(900, 1800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('pencere: başlık, sayfa sayısı, kutu varsayılan açık; vazgeçince bir şey olmaz', (t) async {
    await pump(t);
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    expect(find.byKey(const Key('pdf-import-dialog')), findsOneWidget);
    expect(find.text('7 sayfa'), findsOneWidget);
    expect(t.widget<CheckboxListTile>(find.byKey(const Key('pdf-import-as-book'))).value, isTrue);
    expect(
      t.widget<TextField>(find.byKey(const Key('pdf-import-title'))).controller!.text,
      'Tyt Matematik Soru Bankasi',
    );
    expect(find.byKey(const Key('pdf-import-exists')), findsNothing);
    await t.tap(find.text('Vazgeç'));
    await wait(t);
    expect(find.textContaining('Henüz PDF yok'), findsOneWidget);
    expect(await docs(t), isEmpty);
  });

  testWidgets('pencerede başlık düzenlenir; kutu kapalıysa kitap formu açılmaz', (t) async {
    await pump(t);
    await t.tap(find.byKey(const Key('pdf-import')));
    await wait(t);
    await t.enterText(find.byKey(const Key('pdf-import-title')), 'Benim Adım');
    await t.tap(find.byKey(const Key('pdf-import-as-book')));
    await t.pump();
    await t.tap(find.byKey(const Key('pdf-import-confirm')));
    await wait(t);
    await wait(t);
    expect(find.byKey(const Key('book-save')), findsNothing);
    expect(find.text('Benim Adım'), findsOneWidget);
    expect((await docs(t)).single.bookId, isNull);
    expect(await bookRows(t), isEmpty);
  });

  testWidgets('kutu işaretli: form önceden dolu; kayıtta kitap, bookId ve ofset yazılır', (t) async {
    tall(t);
    await pump(t);
    await importVia(t, asBook: true);
    expect(find.byKey(const Key('book-save')), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const Key('book-title'))).controller!.text, 'Tyt Matematik Soru Bankasi');
    expect(t.widget<TextField>(find.byKey(const Key('book-pages'))).controller!.text, '7');
    expect(find.text('TYT'), findsWidgets);
    expect(find.text('Matematik'), findsWidgets);
    expect(find.text('otomatik dolduruldu'), findsWidgets);
    // Doldurulamayan yalnız yayınevi (isteğe bağlı): "Doldur" yok.
    expect(find.text('Doldur'), findsNothing);
    expect(t.widget<FilledButton>(find.byKey(const Key('book-save'))).onPressed, isNotNull);
    await t.enterText(find.byKey(const Key('book-first-page')), '3');
    await t.enterText(find.byKey(const Key('book-publisher')), 'Palme');
    await t.pump();
    await t.tap(find.byKey(const Key('book-save')));
    await wait(t);
    await wait(t);
    final book = (await bookRows(t)).single;
    expect(book.title, 'Tyt Matematik Soru Bankasi');
    expect(book.examType, 'TYT');
    expect(book.subject, 'Matematik');
    expect(book.pageCount, 7);
    expect(book.publisher, 'Palme');
    final d = (await docs(t)).single;
    expect(d.bookId, book.id);
    expect(d.pageOffset, -2); // kitap 1. sayfa = PDF 3. sayfa
  });

  testWidgets('doldurulamayan zorunlu alanlar vurgulanır; doldurulmadan Kaydet kapalı', (t) async {
    tall(t);
    await pump(t);
    picks = [await namedPick(t, 'kitap_001.pdf')];
    await importVia(t, asBook: true);
    expect(find.text('Doldur'), findsWidgets);
    expect(t.widget<FilledButton>(find.byKey(const Key('book-save'))).onPressed, isNull);
    await t.tap(find.byKey(const Key('book-exam')));
    await t.pumpAndSettle();
    await t.tap(find.text('AYT').last);
    await t.pumpAndSettle();
    // Sınav doldu, ders hâlâ boş: kapalı.
    expect(t.widget<FilledButton>(find.byKey(const Key('book-save'))).onPressed, isNull);
    await t.tap(
      find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('book-subject')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Biyoloji').last);
    await t.pumpAndSettle();
    expect(t.widget<FilledButton>(find.byKey(const Key('book-save'))).onPressed, isNotNull);
    // Geçersiz 1. sayfa da kilitler.
    await t.enterText(find.byKey(const Key('book-first-page')), '99');
    await t.pump();
    expect(t.widget<FilledButton>(find.byKey(const Key('book-save'))).onPressed, isNull);
    await t.enterText(find.byKey(const Key('book-first-page')), '1');
    await t.pump();
    await t.tap(find.byKey(const Key('book-save')));
    await wait(t);
    await wait(t);
    final book = (await bookRows(t)).single;
    expect([book.examType, book.subject], ['AYT', 'Biyoloji']);
    expect((await docs(t)).single.pageOffset, 0);
  });

  testWidgets('şablonla eşleşme önerilir; "Uygula" şablon kitabını ekler ve bağlar', (t) async {
    tall(t);
    await pump(t);
    picks = [await namedPick(t, 'Bilgi Sarmal Ilk Asama Fizik Soru Bankasi.pdf')];
    await importVia(t, asBook: true);
    expect(find.textContaining('Şablonla eşleşti'), findsOneWidget);
    await t.tap(find.byKey(const Key('book-apply-template')));
    await wait(t);
    await wait(t);
    await wait(t);
    final book = (await bookRows(t)).single;
    expect(book.title, contains('Bilgi Sarmal'));
    expect((await docs(t)).single.bookId, book.id);
  });

  testWidgets('menü: kitap olarak ekle, kitapla eşle, ofset ayarla; bağlıysa "Kitap olarak ekle" yok', (t) async {
    tall(t);
    await pump(t);
    await t.runAsync(
      () => db.into(db.books).insert(
            BooksCompanion.insert(
              id: 'k9',
              title: 'Başka Kitap',
              examType: 'AYT',
              subject: 'Fizik',
              pageCount: 100,
              avgQuestionsPerPage: 1,
              createdAt: DateTime(2026),
            ),
          ),
    );
    await importVia(t);
    // Ofset
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    expect(find.text('Kitap olarak ekle'), findsOneWidget);
    await t.tap(find.text('Sayfa ofsetini ayarla'));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('pdf-offset-field')), '9');
    await t.pump();
    expect(t.widget<FilledButton>(find.byKey(const Key('pdf-offset-save'))).onPressed, isNull); // 7 sayfa
    await t.enterText(find.byKey(const Key('pdf-offset-field')), '4');
    await t.pump();
    await t.tap(find.byKey(const Key('pdf-offset-save')));
    await wait(t);
    expect((await docs(t)).single.pageOffset, -3);
    // Kitapla eşle
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('Kitapla eşle'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pdf-link-k9')));
    await wait(t);
    expect((await docs(t)).single.bookId, 'k9');
    await t.pumpAndSettle();
    expect(
      find.descendant(of: find.byType(BookCoverFace), matching: find.text('Başka Kitap')),
      findsOneWidget,
    ); // kapakta bağlı kitap adı
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    expect(find.text('Kitap olarak ekle'), findsNothing);
    await t.tap(find.text('Kitapla eşle'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('pdf-unlink')));
    await wait(t);
    expect((await docs(t)).single.bookId, isNull);
    // Menüden kitap olarak ekle: form açılır.
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('Kitap olarak ekle'));
    await until(t, find.byKey(const Key('book-save')));
    expect(find.byKey(const Key('book-save')), findsOneWidget);
  });

  testWidgets('raf: kapaklar kitap gibi (liste değil), PDF etiketi ve rozeti', (t) async {
    tall(t);
    await pump(t);
    await importVia(t);
    final d = (await docs(t)).single;
    expect(find.byKey(Key('pdf-item-${d.id}')), findsOneWidget);
    expect(find.text('PDF'), findsNWidgets(2)); // etiket + rozet
    expect(find.byType(ListTile), findsNothing);
  });
}
