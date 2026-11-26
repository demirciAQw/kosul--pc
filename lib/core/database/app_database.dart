import 'package:drift/drift.dart';

import '../ledger/ledger_service.dart';
import 'converters.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [
  Books,
  ContentNodes,
  CurriculumNodes,
  StudyPlans,
  PlanTasks,
  StudySessions,
  SessionItems,
  QuestionCards,
  ReviewStates,
  MockExams,
  MockExamSections,
  TestResults,
  StudyNotes,
  NotePhotos,
  OcrResults,
  AppMeta,
  AnlikNotes,
  Tags,
  AnlikNoteTags,
  QuestionCardTags,
  People,
  AnlikNotePeople,
  AnlikLinks,
  Degisiklikler,
  Baglam,
  Cakismalar,
  EsitlemeDurum,
  SilmeOnerileri,
  InkStrokes,
  PdfDocuments,
  InkNotebooks,
  InkNotePages,
  InkNotebookTags,
  InkNotebookPeople,
  InkPageTags,
  InkPagePeople,
  PdfPageLayers,
  InkPageText,
  SaglikGunluk,
  SaglikStres,
  SaglikUykuOturum,
  InkFolders,
  InkPageLinks,
  InkPageItems,
])
class AppDatabase extends _$AppDatabase {
  /// Testlerde: `AppDatabase(NativeDatabase.memory())`
  AppDatabase(QueryExecutor executor, [this.ledgerSource = 'telefon']) : super(executor);

  /// Bu cihazın değişiklik defterindeki varsayılan kaynağı: `telefon` ya da `pc`.
  final String ledgerSource;

  /// v2: fotoğrafsız/çözümsüz kartlar, soru numarası, kitapsız oturum, denemeler.
  /// v3: testlerin kesin soru sayısı, planların tamamlanma tarihi.
  /// v4: test ilerlemesi (çözüldü/çözülmedi), "Diğer" nedeni için açıklama.
  /// v5: kartlarda serbest konu/kazanım adı (karneden içe aktarma).
  /// v6: eski sürümlerden kalan yetim tekrar kayıtlarını temizler.
  /// v7: ders notları (study_notes).
  /// v12: anlık notlar, ortak etiketler, kişiler ve bağlar.
  /// v13: değişiklik defteri, bağlam, çakışmalar, senkron imleçleri; tetikleyiciler.
  /// v14: silme önerileri (Claude silmez, işaretler).
  /// v15: kalem çizgileri (ink_strokes), noktalar sıkıştırılmış BLOB.
  /// v16: PDF belgeleri (pdf_documents): satır senkron olur, dosya olmaz.
  /// v17: soru kartında PDF koordinatı (pdf_document_id, pdf_page, pdf_box_*).
  /// v18: çizgi -> soru bağı (ink_strokes.question_id), çözüm katmanları.
  /// v19: kalemli defter (ink_notebooks, ink_note_pages) ve etiket/kişi bağları.
  /// v20: PDF sayfa katmanları (pdf_page_layers): çizim katmanları (full/question), dosya değişmez.
  /// v21: el yazısı metni (ink_page_text): sayfa başına türev metin, çizgiler değişmez.
  /// v22: sağlık verisi (saglik_gunluk, saglik_stres, saglik_uyku_oturum); defter dışı.
  /// v23: defter klasörleri, sayfa başlığı/konu/alt sayfa/Pano konumu, sayfa bağlantıları, sayfa öğeleri.
  @override
  int get schemaVersion => 23;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // Aynı anda yalnızca BİR koşan oturum olabilir: kısmi benzersiz indeks.
          await customStatement(
            'CREATE UNIQUE INDEX ux_single_running_session '
            "ON study_sessions(status) WHERE status = 'running'",
          );
          await _createV2Indexes();
          await _createLedgerTables(m);
          await _createInkIndexes();
          await _createNotebookIndexes();
          await _createPdfLayerIndexes();
          await _createPageTextIndexes();
          await _createHealthIndexes();
          await _createBoardIndexes();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(sessionItems, sessionItems.subject);
            await m.addColumn(sessionItems, sessionItems.activity);
            await m.createTable(mockExams);
            await m.createTable(mockExamSections);
            // Tablo yeniden kurulur: soru fotoğrafı isteğe bağlı olur, "çözüm
            // zorunlu" CHECK kuralı kalkar, yeni sütunlar eklenir. Drift eski
            // indeksleri kendisi yeniden oluşturur. (Bu aşamada foreign_keys
            // kapalıdır; tekrar durumları silinmez.)
            await m.alterTable(TableMigration(questionCards, newColumns: [
              questionCards.questionNo,
              questionCards.testLabel,
              questionCards.sessionItemId,
              questionCards.mockExamId,
              questionCards.reasonNote,
              questionCards.topicText,
              questionCards.correctAnswer,
              questionCards.givenAnswer,
            ]));
            await _createV2Indexes();
          }
          if (from < 3) {
            await m.addColumn(contentNodes, contentNodes.questionCount);
            await m.addColumn(studyPlans, studyPlans.completedAt);
          }
          if (from < 4) {
            await m.createTable(testResults);
            // v2 geçişindeki alterTable güncel tanımı kurduğu için sütun zaten
            // var olabilir; yalnızca eksikse ekle.
            final cols = await customSelect('PRAGMA table_info(question_cards)').get();
            if (!cols.any((c) => c.read<String>('name') == 'reason_note')) {
              await m.addColumn(questionCards, questionCards.reasonNote);
            }
            await _createV2Indexes();
          }
          if (from < 8) {
            final cols = await customSelect('PRAGMA table_info(question_cards)').get();
            final names = {for (final c in cols) c.read<String>('name')};
            if (!names.contains('correct_answer')) await m.addColumn(questionCards, questionCards.correctAnswer);
            if (!names.contains('given_answer')) await m.addColumn(questionCards, questionCards.givenAnswer);
          }
          if (from < 7) {
            await m.createTable(studyNotes);
          }
          if (from < 6) {
            await customStatement(
              'DELETE FROM review_states WHERE card_id NOT IN (SELECT id FROM question_cards)',
            );
          }
          if (from < 5) {
            final cols = await customSelect('PRAGMA table_info(question_cards)').get();
            if (!cols.any((c) => c.read<String>('name') == 'topic_text')) {
              await m.addColumn(questionCards, questionCards.topicText);
            }
          }
          // Notlar tablosundan (v7) sonra: fotoğraflar ona bağlı.
          if (from < 9) {
            await m.createTable(notePhotos);
          }
          // Fotoğraflardaki metin (ML Kit).
          if (from < 10) {
            await m.createTable(ocrResults); // yeni sütunlarla birlikte oluşur
          }
          if (from == 10) {
            await m.addColumn(ocrResults, ocrResults.structureJson);
          }
          // Anlık notlar ve etiketler (v12). Sıra: bağlananlar önce.
          if (from < 12) {
            await m.createTable(anlikNotes);
            await m.createTable(tags);
            await m.createTable(anlikNoteTags);
            await m.createTable(questionCardTags);
            await m.createTable(people);
            await m.createTable(anlikNotePeople);
            await m.createTable(anlikLinks);
          }
          if (from < 13) await _createLedgerTables(m);
          if (from < 14) await m.createTable(silmeOnerileri);
          if (from < 15) {
            await m.createTable(inkStrokes);
            await _createInkIndexes();
          }
          if (from < 16) await m.createTable(pdfDocuments);
          // v2'deki alterTable güncel tanımı kurduğu için (from < 2) sütunlar
          // zaten olabilir; yalnızca eksikse ekle (12→17, 14→17, 16→17 hepsi buradan).
          if (from < 17) {
            final cols = await customSelect('PRAGMA table_info(question_cards)').get();
            final names = {for (final c in cols) c.read<String>('name')};
            if (!names.contains('pdf_document_id')) await m.addColumn(questionCards, questionCards.pdfDocumentId);
            if (!names.contains('pdf_page')) await m.addColumn(questionCards, questionCards.pdfPage);
            if (!names.contains('pdf_box_left')) await m.addColumn(questionCards, questionCards.pdfBoxLeft);
            if (!names.contains('pdf_box_top')) await m.addColumn(questionCards, questionCards.pdfBoxTop);
            if (!names.contains('pdf_box_right')) await m.addColumn(questionCards, questionCards.pdfBoxRight);
            if (!names.contains('pdf_box_bottom')) await m.addColumn(questionCards, questionCards.pdfBoxBottom);
          }
          // v18: çizgi -> soru bağı. ink_strokes v15'te güncel tanımla kurulmuş olabilir.
          if (from < 18) {
            final cols = await customSelect('PRAGMA table_info(ink_strokes)').get();
            final names = {for (final c in cols) c.read<String>('name')};
            if (!names.contains('question_id')) await m.addColumn(inkStrokes, inkStrokes.questionId);
            await customStatement('CREATE INDEX IF NOT EXISTS ix_ink_question ON ink_strokes(question_id, attempt_no)');
          }
          // v19: tablolar yoksa kurulur (IF NOT EXISTS: Drift'in createTable'ı da öyle).
          if (from < 19) {
            await m.createTable(inkNotebooks);
            await m.createTable(inkNotePages);
            await m.createTable(inkNotebookTags);
            await m.createTable(inkNotebookPeople);
            await m.createTable(inkPageTags);
            await m.createTable(inkPagePeople);
            await _createNotebookIndexes();
          }
          // v20: tablo yoksa kurulur (14/18/19 → 20 hepsi buradan).
          if (from < 20) {
            await m.createTable(pdfPageLayers);
            await _createPdfLayerIndexes();
          }
          // v21: tablo yoksa kurulur (14/17/19/20 → 21 hepsi buradan).
          if (from < 21) {
            await m.createTable(inkPageText);
            await _createPageTextIndexes();
          }
          // v22: sağlık tabloları (14/20/21 → 22 hepsi buradan); eskilere dokunulmaz.
          if (from < 22) {
            await m.createTable(saglikGunluk);
            await m.createTable(saglikStres);
            await m.createTable(saglikUykuOturum);
            await _createHealthIndexes();
          }
          // v23: tablolar yoksa kurulur; sütunlar yalnızca eksikse eklenir (v19 öncesinden
          // gelenlerde ink_notebooks/ink_note_pages yukarıda zaten güncel tanımla kurulmuştur).
          if (from < 23) {
            await m.createTable(inkFolders);
            await m.createTable(inkPageLinks);
            await m.createTable(inkPageItems);
            final nb = {for (final c in await customSelect('PRAGMA table_info(ink_notebooks)').get()) c.read<String>('name')};
            if (!nb.contains('folder_id')) await m.addColumn(inkNotebooks, inkNotebooks.folderId);
            final pg = {for (final c in await customSelect('PRAGMA table_info(ink_note_pages)').get()) c.read<String>('name')};
            if (!pg.contains('title')) await m.addColumn(inkNotePages, inkNotePages.title);
            if (!pg.contains('konu_id')) await m.addColumn(inkNotePages, inkNotePages.konuId);
            if (!pg.contains('parent_page_id')) await m.addColumn(inkNotePages, inkNotePages.parentPageId);
            if (!pg.contains('board_x')) await m.addColumn(inkNotePages, inkNotePages.boardX);
            if (!pg.contains('board_y')) await m.addColumn(inkNotePages, inkNotePages.boardY);
            if (!pg.contains('board_w')) await m.addColumn(inkNotePages, inkNotePages.boardW);
            if (!pg.contains('board_h')) await m.addColumn(inkNotePages, inkNotePages.boardH);
            await _createBoardIndexes();
          }
          // Tablolar yeniden kurulmuş ya da sütun eklenmiş olabilir: tetikleyiciler baştan.
          await LedgerService(this).installTriggers(rebuild: true);
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          await LedgerService(this).ensureReady(defaultSource: ledgerSource);
        },
      );

  Future<void> _createLedgerTables(Migrator m) async {
    await m.createTable(degisiklikler);
    await m.createTable(baglam);
    await m.createTable(cakismalar);
    await m.createTable(esitlemeDurum);
    await customStatement('CREATE INDEX IF NOT EXISTS ix_degisiklik_satir ON degisiklikler(tablo, satir_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_degisiklik_oturum ON degisiklikler(oturum_id)');
  }

  Future<void> _createInkIndexes() async {
    await customStatement('CREATE INDEX IF NOT EXISTS ix_ink_pdf ON ink_strokes(pdf_document_id, pdf_page)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_ink_note ON ink_strokes(note_id, note_page)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_ink_question ON ink_strokes(question_id, attempt_no)');
  }

  Future<void> _createPdfLayerIndexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS ix_pdf_layer_doc ON pdf_page_layers(pdf_document_id, page)');
  }

  Future<void> _createHealthIndexes() async {
    await customStatement('CREATE INDEX IF NOT EXISTS ix_saglik_gunluk_gun ON saglik_gunluk(gun)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_saglik_stres_zaman ON saglik_stres(zaman)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_saglik_uyku_bitis ON saglik_uyku_oturum(bitis)');
  }

  Future<void> _createBoardIndexes() async {
    await customStatement('CREATE INDEX IF NOT EXISTS ix_klasor_ust ON ink_folders(parent_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_klasor ON ink_notebooks(folder_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_sayfa_konu ON ink_note_pages(konu_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_sayfa_baglanti ON ink_page_links(notebook_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_sayfa_ogeleri ON ink_page_items(page_id)');
  }

  Future<void> _createPageTextIndexes() async {
    await customStatement('CREATE INDEX IF NOT EXISTS ix_page_text_page ON ink_page_text(page_id)');
  }

  Future<void> _createNotebookIndexes() async {
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_sayfa ON ink_note_pages(notebook_id, sort_order)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_etiket ON ink_notebook_tags(tag_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_kisi ON ink_notebook_people(person_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_sayfa_etiket ON ink_page_tags(tag_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_defter_sayfa_kisi ON ink_page_people(person_id)');
  }

  Future<void> _createV2Indexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS ix_cards_session_item ON question_cards(session_item_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_cards_mock_exam ON question_cards(mock_exam_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_cards_session ON question_cards(session_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS ix_mock_sections_exam ON mock_exam_sections(exam_id)');
    await customStatement('CREATE INDEX IF NOT EXISTS ix_cards_content_node ON question_cards(content_node_id)');
  }
}
