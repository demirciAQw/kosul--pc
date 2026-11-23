import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kocum/cli/kocum_cli.dart';
import 'package:kocum/core/database/app_database.dart';
import 'package:kocum/core/ledger/ledger_service.dart';
import 'package:kocum/core/media/media_storage.dart';
import 'package:kocum/core/utils/id_generator.dart';
import 'package:kocum/desktop/import/data/snapshot_merger.dart';
import 'package:kocum/features/library/domain/library.dart';
import 'package:kocum/features/ocr/data/ocr_repository_impl.dart';
import 'package:kocum/features/ocr/domain/auto_tags.dart';
import 'package:kocum/features/ocr/domain/ocr.dart';
import 'package:kocum/features/ocr/domain/question_text.dart';
import 'package:kocum/features/pdf/data/pdf_question_service.dart';
import 'package:kocum/features/pdf/domain/pdf_document_record.dart';
import 'package:kocum/features/pdf/domain/pdf_engine.dart';
import 'package:kocum/features/pdf/domain/question_box.dart';
import 'package:kocum/features/question_bank/data/question_card_json.dart';
import 'package:kocum/features/question_bank/data/question_card_repository_impl.dart';
import 'package:kocum/features/question_bank/domain/question_bank.dart';
import 'package:kocum/features/question_bank/domain/question_card.dart';
import 'package:kocum/features/question_bank/domain/srs.dart';
import 'package:path/path.dart' as p;

class _Ids implements IdGenerator {
  var n = 0;
  @override
  String next() => 'k${n++}';
}

class _DirMedia implements MediaStorage {
  _DirMedia(this.root);
  final Directory root;
  var n = 0;
  @override
  Future<String> importFile(String sourcePath, {required String bucket}) async {
    final rel = '$bucket/${n++}${p.extension(sourcePath)}';
    final t = resolve(rel);
    await t.parent.create(recursive: true);
    await File(sourcePath).copy(t.path);
    return rel;
  }

  @override
  File resolve(String relativePath) => File('${root.path}/$relativePath');
  @override
  Future<void> delete(String relativePath) async {
    if (resolve(relativePath).existsSync()) resolve(relativePath).deleteSync();
  }

  @override
  Future<void> discardTemp(String? absolutePath) async {}
}

/// Metni ve boyutu ayarlanabilir sahte motor; sayfa çiziminde dolu BGRA piksel verir.
class _Engine implements PdfEngine {
  _Engine(this.text);
  String text;
  int closed = 0;
  @override
  Future<PdfEngineDocument> openBytes(Uint8List b) => throw UnimplementedError();
  @override
  Future<PdfEngineDocument> openFile(String path) async => _Doc(this);
}

class _Doc implements PdfEngineDocument {
  _Doc(this.e);
  final _Engine e;
  @override
  int get pageCount => 3;
  @override
  Future<void> close() async => e.closed++;
  @override
  Future<PdfPageSize> pageSize(int page) async => const PdfPageSize(612, 792);
  @override
  Future<PdfRenderedImage> renderPage(int page, {required int width, required int height}) async {
    final b = Uint8List(width * height * 4);
    for (var i = 0; i < b.length; i += 4) {
      b[i] = 200; // B
      b[i + 1] = 100; // G
      b[i + 2] = 50; // R
      b[i + 3] = 255;
    }
    return PdfRenderedImage(width: width, height: height, bytes: b, format: PdfPixelFormat.bgra);
  }

  @override
  Future<String> textInBox(int page, PdfBox box) async => e.text;
}

class _Ocr implements OcrEngine {
  _Ocr(this.lines);
  final List<String> lines;
  int calls = 0;
  String? lastPath;
  bool existedDuringCall = false;
  @override
  Future<List<OcrLine>> recognize(String absolutePath) async {
    calls++;
    lastPath = absolutePath;
    existedDuringCall = File(absolutePath).existsSync();
    return [for (final (i, l) in lines.indexed) OcrLine(l, top: i * 20.0, height: 16, width: 300)];
  }
}

const _doc = PdfDocumentRecord(id: 'd1', sha256: 'd1', title: 'Sınav PDF', pageCount: 3, fileName: 'a.pdf');
const _box = PdfBox(72, 100, 372, 400);
const _text = 'Bir fonksiyonun türevi alınırken türev ve teğet doğrusu kullanılır. Buna göre hangisi doğrudur?';

Future<AppDatabase> _open([String source = 'telefon']) async {
  final db = AppDatabase(NativeDatabase.memory(), source);
  addTearDown(db.close);
  await db.customSelect('SELECT 1').get();
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late TopicLexicon lexicon;
  setUpAll(() {
    lexicon = TopicLexicon.fromJson(jsonDecode(File('assets/meb/konu_sozlugu.json').readAsStringSync()) as Map<String, dynamic>);
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pdf_soru');
  });
  tearDown(() => tmp.delete(recursive: true));

  PdfQuestionService service(AppDatabase db, _Engine engine, {OcrEngine? ocr, QuestionCardRepository? cards}) {
    return PdfQuestionService(
      engine: engine,
      cards: cards ?? DriftQuestionCardRepository(db),
      media: _DirMedia(Directory('${tmp.path}/media')),
      ids: _Ids(),
      clock: () => DateTime(2026, 11, 1),
      tempDir: Directory(tmp.path)..createSync(),
      lexicon: () async => lexicon,
      ocr: ocr,
      ocrRepository: DriftOcrRepository(db),
    );
  }

  group('depo', () {
    test('PDF alanları yazılır ve okunur; PDF\'siz kart boş okunur; JSON gidiş-dönüş', () async {
      final db = await _open();
      final repo = DriftQuestionCardRepository(db);
      final base = QuestionCard(
        id: 'a',
        status: QuestionStatus.wrong,
        origin: QuestionOrigin.independent,
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 5,
        createdAt: DateTime(2026),
      );
      await repo.insert(base);
      await repo.insert(QuestionCard(
        id: 'b',
        status: QuestionStatus.blank,
        origin: QuestionOrigin.independent,
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 5,
        createdAt: DateTime(2026),
        pdfDocumentId: 'd1',
        pdfPage: 2,
        pdfBox: _box,
      ));
      final a = (await repo.findById('a'))!;
      expect([a.pdfDocumentId, a.pdfPage, a.pdfBox, a.hasPdfAnchor], [null, null, null, false]);
      final b = (await repo.findById('b'))!;
      expect([b.pdfDocumentId, b.pdfPage, b.pdfBox], ['d1', 2, _box]);
      expect(b.hasPdfAnchor, isTrue);
      expect(b.copyWith(isStarred: true).pdfBox, _box);

      final back = questionCardFromJson(jsonDecode(jsonEncode(b.toJson())) as Map<String, dynamic>);
      expect([back.pdfDocumentId, back.pdfPage, back.pdfBox], ['d1', 2, _box]);
      expect(a.toJson().containsKey('pdfBox'), isFalse);
      // Bozuk kutu yok sayılır.
      final bad = {...b.toJson(), 'pdfBox': [10, 10, 5, 5]};
      expect(questionCardFromJson(bad).pdfBox, isNull);
    });

    test('düzenleme PDF bağını korur', () async {
      final db = await _open();
      final repo = DriftQuestionCardRepository(db);
      final svc = service(db, _Engine(_text));
      final card = await svc.save(
        document: _doc,
        pdfPath: 'x.pdf',
        page: 1,
        box: _box,
        status: QuestionStatus.wrong,
        subject: 'TYT Matematik',
      );
      final update = UpdateQuestionCard(
          repository: repo, media: _DirMedia(Directory('${tmp.path}/media')), clock: () => DateTime(2026, 11, 2));
      final saved = await update(
        card,
        const QuestionDraft(
            status: QuestionStatus.blank, origin: QuestionOrigin.independent, sourceName: 'x', subject: 'TYT Matematik'),
      );
      expect([saved.pdfDocumentId, saved.pdfPage, saved.pdfBox], ['d1', 1, _box]);
      expect((await repo.findById(card.id))!.pdfBox, _box);
    });
  });

  group('servis', () {
    test('metin katmanı: öneri, önizleme, kart, okuma kaydı ve tekrar durumu', () async {
      final db = await _open();
      final engine = _Engine(_text);
      final svc = service(db, engine);
      final a = await svc.analyze('x.pdf', 1, _box);
      expect(a.source, BoxTextSource.textLayer);
      expect(a.suggestion.subject, 'TYT Matematik');
      expect(a.suggestion.topic, 'Türev');
      expect(engine.closed, 1);

      final card = await svc.save(
        document: _doc,
        pdfPath: 'x.pdf',
        page: 1,
        box: _box,
        status: QuestionStatus.wrong,
        subject: a.suggestion.subject!,
        analysis: a,
        topicText: a.suggestion.topic,
      );
      expect([card.pdfDocumentId, card.pdfPage, card.pdfBox, card.status], ['d1', 1, _box, QuestionStatus.wrong]);
      expect(card.topicText, 'Türev');
      expect(card.sourceName, 'Sınav PDF');
      expect(card.origin, QuestionOrigin.independent);
      // Önizleme kalıcı depoda: eklenti yokken PNG (dart:ui WebP üretemez).
      final img = File('${tmp.path}/media/${card.questionImage}');
      expect(card.questionImage, endsWith('.png'));
      expect(img.readAsBytesSync().sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      // Geçici dosya kalmadı.
      expect(tmp.listSync().whereType<File>(), isEmpty);
      // Okuma kaydı: otomatik etiketler fotoğraf akışıyla aynı çalışır.
      final rec = (await DriftOcrRepository(db).watchAll().first)[OcrJob.questionId(card.id)]!;
      expect(rec.ok, isTrue);
      expect(rec.imagePath, card.questionImage);
      expect(autoTag(lexicon: lexicon, subject: card.subject, record: rec).topic, 'Türev');
      // Yanlış kart tekrar kuyruğunda, doğru değil.
      expect(await DriftQuestionCardRepository(db).reviewStateOf(card.id), isNotNull);
      final ok = await svc.save(
          document: _doc, pdfPath: 'x.pdf', page: 0, box: _box, status: QuestionStatus.correct, subject: 'TYT Matematik');
      expect(await DriftQuestionCardRepository(db).reviewStateOf(ok.id), isNull);
    });

    test('kitaba bağlı PDF: kitap haritası kartı doldurur', () async {
      final db = await _open();
      final svc = service(db, _Engine(_text));
      final book = _book();
      // Sayfa 4 (0'dan: 3), ofset 2 → kitap sayfası 6.
      final card = await svc.save(
        document: const PdfDocumentRecord(
            id: 'd1', sha256: 'd1', title: 'PDF', pageCount: 30, fileName: 'a.pdf', bookId: 'k1', pageOffset: 2),
        pdfPath: 'x.pdf',
        page: 3,
        box: _box,
        status: QuestionStatus.blank,
        subject: 'TYT Matematik',
        book: book,
      );
      expect([card.bookId, card.contentNodeId, card.origin, card.sourceName], ['k1', 't1', QuestionOrigin.book, 'Kitap']);
      expect(card.testLabel, 'Test 1');
    });

    test('metin yok + ML Kit var: kutu resme çizilip okunur; geçici dosya silinir', () async {
      final db = await _open();
      final ocr = _Ocr(['Bir fonksiyonun türevi alınırken türev ve teğet doğrusu', 'kullanılır. Buna göre hangisi doğrudur?']);
      final svc = service(db, _Engine(''), ocr: ocr);
      final a = await svc.analyze('x.pdf', 0, _box);
      expect(ocr.calls, 1);
      expect(ocr.existedDuringCall, isTrue);
      expect(File(ocr.lastPath!).existsSync(), isFalse);
      expect(a.source, BoxTextSource.ocr);
      expect(a.suggestion.topic, 'Türev');
      expect(a.lines, hasLength(2));
    });

    test('metin yok + ML Kit yok (Linux): metinsiz kaydedilir, okuma kaydı yazılmaz', () async {
      final db = await _open();
      final svc = service(db, _Engine(''));
      final a = await svc.analyze('x.pdf', 0, _box);
      expect([a.source, a.text, a.suggestion.isEmpty], [BoxTextSource.none, '', true]);
      final card = await svc.save(
          document: _doc,
          pdfPath: 'x.pdf',
          page: 0,
          box: _box,
          status: QuestionStatus.blank,
          subject: 'TYT Türkçe',
          analysis: a);
      expect(card.questionImage, isNotNull);
      expect(await DriftOcrRepository(db).watchAll().first, isEmpty);
    });

    test('ML Kit hata verirse metinsiz devam eder', () async {
      final db = await _open();
      final svc = service(db, _Engine(''), ocr: _FailingOcr());
      expect((await svc.analyze('x.pdf', 0, _box)).source, BoxTextSource.none);
    });

    test('kart yazılamazsa önizleme dosyası geri silinir', () async {
      final db = await _open();
      final svc = service(db, _Engine(_text), cards: _FailingRepo(db));
      await expectLater(
        svc.save(document: _doc, pdfPath: 'x.pdf', page: 0, box: _box, status: QuestionStatus.wrong, subject: 'TYT Matematik'),
        throwsStateError,
      );
      final media = Directory('${tmp.path}/media');
      expect(media.existsSync() ? media.listSync(recursive: true).whereType<File>() : const [], isEmpty);
      expect(tmp.listSync().whereType<File>(), isEmpty);
    });
  });

  group('göç', () {
    /// Eski sürümü taklit eder: tetikleyiciler, PDF sütunları ve sonraki tablolar gider.
    Future<void> migrate(int from) async {
      final file = File('${tmp.path}/k.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.customStatement(
          "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at) "
          "VALUES ('eski', 'wrong', 'independent', 'x', 'TYT Matematik', 3, '', 1767225600)");
      for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) {
        await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
      }
      for (final c in ['pdf_document_id', 'pdf_page', 'pdf_box_left', 'pdf_box_top', 'pdf_box_right', 'pdf_box_bottom']) {
        await d.customStatement('ALTER TABLE question_cards DROP COLUMN $c');
      }
      final drop = [
        if (from < 16) 'pdf_documents',
        if (from < 15) 'ink_strokes',
        if (from < 14) 'silme_onerileri',
        if (from < 13) ...['degisiklikler', '_baglam', 'cakismalar', 'esitleme_durum'],
      ];
      for (final t in drop) {
        await d.customStatement('DROP TABLE "$t"');
      }
      await d.customStatement('PRAGMA user_version = $from');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      addTearDown(d.close);
      final cols = {for (final c in await d.customSelect('PRAGMA table_info(question_cards)').get()) c.read<String>('name')};
      expect(cols, containsAll(['pdf_document_id', 'pdf_page', 'pdf_box_left', 'pdf_box_top', 'pdf_box_right', 'pdf_box_bottom']));
      expect((await d.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 22);
      final repo = DriftQuestionCardRepository(d);
      expect((await repo.findById('eski'))!.hasPdfAnchor, isFalse);
      // Yeni sütunlu satır yazılır ve tetikleyici onu kapsar.
      await repo.insert(QuestionCard(
        id: 'yeni',
        status: QuestionStatus.wrong,
        origin: QuestionOrigin.independent,
        sourceName: 'x',
        subject: 'TYT Matematik',
        difficulty: 5,
        createdAt: DateTime(2026),
        pdfDocumentId: 'd1',
        pdfPage: 4,
        pdfBox: _box,
      ));
      expect((await repo.findById('yeni'))!.pdfBox, _box);
      final h = (await LedgerService(d).history()).where((c) => c.table == 'question_cards' && c.rowId == 'yeni');
      expect(h, hasLength(1));
      final json = jsonDecode(h.single.neu!) as Map<String, dynamic>;
      expect([json['pdf_document_id'], json['pdf_page'], json['pdf_box_left'], json['pdf_box_bottom']], ['d1', 4, 72.0, 400.0]);
    }

    test('v16 -> v17', () => migrate(16));
    test('v14 -> v17', () => migrate(14));
    test('v12 -> v17', () => migrate(12));

    test('sütunlar zaten varsa (v2 tablo yeniden kurulumu gibi) göç çift eklemez', () async {
      final file = File('${tmp.path}/k2.sqlite');
      var d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.close();
      // Zaten güncel şema, user_version düşük: sütunlar var, göç hata vermemeli.
      d = AppDatabase(NativeDatabase(file));
      await d.customSelect('SELECT 1').get();
      await d.close();
      var raw = AppDatabase(NativeDatabase(file));
      await raw.customStatement('PRAGMA user_version = 16');
      await raw.close();
      raw = AppDatabase(NativeDatabase(file));
      addTearDown(raw.close);
      expect((await raw.customSelect('PRAGMA user_version').getSingle()).read<int>('user_version'), 22);
    });
  });

  group('ledger, birleştirici, CLI', () {
    test('tetikleyici PDF alanlarının güncellenmesini de kaydeder ve geri alınır', () async {
      final db = await _open();
      final ledger = LedgerService(db);
      final repo = DriftQuestionCardRepository(db);
      await repo.insert(QuestionCard(
          id: 'q',
          status: QuestionStatus.wrong,
          origin: QuestionOrigin.independent,
          sourceName: 'x',
          subject: 'TYT Matematik',
          difficulty: 5,
          createdAt: DateTime(2026)));
      await db.customStatement("UPDATE question_cards SET pdf_page = 3 WHERE id = 'q'");
      final ch = (await ledger.history()).firstWhere((c) => c.op == 'degistir' && c.table == 'question_cards');
      expect((jsonDecode(ch.old!) as Map)['pdf_page'], isNull);
      expect((jsonDecode(ch.neu!) as Map)['pdf_page'], 3);
      await ledger.undoChange(ch.id);
      expect((await repo.findById('q'))!.pdfPage, isNull);
    });

    test('masaüstü birleştirici: yeni ve eski (v16) telefon kopyası', () async {
      final desktop = AppDatabase(NativeDatabase.memory());
      addTearDown(desktop.close);
      await desktop.customSelect('SELECT 1').get();
      Future<File> phone(String name, {required bool old}) async {
        final f = File('${tmp.path}/$name');
        final d = AppDatabase(NativeDatabase(f));
        await d.customSelect('SELECT 1').get();
        await d.customStatement(
            "INSERT INTO question_cards (id, status, origin, source_name, subject, difficulty, search_text, created_at, "
            "pdf_document_id, pdf_page, pdf_box_left, pdf_box_top, pdf_box_right, pdf_box_bottom) "
            "VALUES ('${name}q', 'wrong', 'independent', 'x', 'TYT Matematik', 3, '', 1767225600, 'd1', 5, 1.5, 2.5, 300.5, 400.5)");
        if (old) {
          for (final r in await d.customSelect("SELECT name FROM sqlite_master WHERE type = 'trigger'").get()) {
            await d.customStatement('DROP TRIGGER "${r.read<String>('name')}"');
          }
          for (final c in ['pdf_document_id', 'pdf_page', 'pdf_box_left', 'pdf_box_top', 'pdf_box_right', 'pdf_box_bottom']) {
            await d.customStatement('ALTER TABLE question_cards DROP COLUMN $c');
          }
          await d.customStatement('PRAGMA user_version = 16');
        }
        await d.close();
        return f;
      }

      final yeni = await phone('yeni', old: false);
      await SnapshotMerger(desktop).merge(yeni);
      final c = (await DriftQuestionCardRepository(desktop).findById('yeniq'))!;
      expect([c.pdfDocumentId, c.pdfPage, c.pdfBox], ['d1', 5, const PdfBox(1.5, 2.5, 300.5, 400.5)]);
      final r = await SnapshotMerger(desktop).merge(await phone('eski', old: true));
      expect(r.firstWhere((t) => t.table == 'question_cards').added, 1);
      expect((await DriftQuestionCardRepository(desktop).findById('eskiq'))!.hasPdfAnchor, isFalse);
      // Telefon kopyasının PDF alanları ikinci birleştirmede ezilmez/değişmez.
      await SnapshotMerger(desktop).merge(yeni);
      expect((await DriftQuestionCardRepository(desktop).findById('yeniq'))!.pdfPage, 5);
    });

    test('kocum CLI: PDF sütunları düzeltilebilir ve sorgulanır', () async {
      final db = AppDatabase(NativeDatabase.memory(), 'pc');
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      await DriftQuestionCardRepository(db).insert(QuestionCard(
          id: 'q1',
          status: QuestionStatus.wrong,
          origin: QuestionOrigin.independent,
          sourceName: 'x',
          subject: 'TYT Matematik',
          difficulty: 5,
          createdAt: DateTime(2026),
          pdfDocumentId: 'd1',
          pdfPage: 1,
          pdfBox: _box));
      Future<(int, Map<String, dynamic>)> run(List<String> args) async {
        final out = StringBuffer();
        final code = await runKocum(args,
            db: db, out: out.writeln, err: (_) {}, now: () => DateTime(2026, 11, 1), env: const {}, ids: _Ids());
        return (code, jsonDecode(out.toString().isEmpty ? '{}' : out.toString()) as Map<String, dynamic>);
      }

      expect((await run(['duzelt', 'question_cards', 'q1', 'pdf_page', '7'])).$1, 0);
      expect((await run(['duzelt', 'question_cards', 'q1', 'pdf_box_left', '10.5'])).$1, 0);
      final c = (await DriftQuestionCardRepository(db).findById('q1'))!;
      expect([c.pdfPage, c.pdfBox!.left], [7, 10.5]);
      final q = await run(['sorgu', 'SELECT pdf_document_id, pdf_page, pdf_box_right FROM question_cards']);
      expect(q.$2['satirlar'], [
        {'pdf_document_id': 'd1', 'pdf_page': 7, 'pdf_box_right': 372.0},
      ]);
    });
  });
}

Book _book() => Book(
      id: 'k1',
      title: 'Kitap',
      examType: 'TYT',
      subject: 'Matematik',
      pageCount: 100,
      avgQuestionsPerPage: 2,
      createdAt: DateTime(2026),
      roots: const [
        ContentNode(id: 't1', level: NodeLevel.topic, title: 'Test 1', pageStart: 1, pageEnd: 10),
      ],
    );

class _FailingOcr implements OcrEngine {
  @override
  Future<List<OcrLine>> recognize(String absolutePath) => throw StateError('ML Kit yok');
}

class _FailingRepo extends DriftQuestionCardRepository {
  _FailingRepo(super.db);
  @override
  Future<void> insert(QuestionCard card, {ReviewState? review}) => throw StateError('yazılamadı');
}
