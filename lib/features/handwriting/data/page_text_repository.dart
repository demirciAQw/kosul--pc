import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../../../core/text/turkish_text.dart';
import '../domain/transcript.dart';

/// Bir sayfanın kayıtlı el yazısı metni.
class PageTextRecord {
  const PageTextRecord({
    required this.pageId,
    required this.text,
    required this.lines,
    required this.languageCode,
    required this.strokeSig,
    required this.recognizedAt,
    required this.updatedAt,
  });

  final String pageId;
  final String text;
  final List<TranscriptLine> lines;
  final String languageCode;
  final String strokeSig;
  final DateTime recognizedAt;
  final DateTime updatedAt;
}

/// Arama sonucu: defter + eşleşen sayfa.
class PageTextHit {
  const PageTextHit({required this.notebookId, required this.pageId, required this.pageNumber, required this.snippet});
  final String notebookId;
  final String pageId;

  /// Defterdeki sıra (1'den; silinmemiş sayfalar arasında).
  final int pageNumber;
  final String snippet;
}

/// El yazısı metni deposu. Metin TÜREV veridir; çizgilere dokunulmaz. Satırın kimliği
/// sayfa kimliğidir (sayfa başına tek satır). Silme yumuşaktır; yeniden kaydetme geri getirir.
class PageTextRepository {
  PageTextRepository(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Sayfanın GÖRÜNÜR çizgilerinin özeti (defter düzenleyicisinin okuduğu çizgiler:
  /// deneme 0, katman 0, soruya bağlı değil, silinmemiş).
  Future<String> currentSig(String pageId) async {
    final t = _db.inkStrokes;
    final rows = await (_db.selectOnly(t)
          ..addColumns([t.id, t.updatedAt])
          ..where(t.noteId.equals(pageId) &
              t.deleted.equals(false) &
              t.attemptNo.equals(0) &
              t.layer.equals(0) &
              t.questionId.isNull()))
        .get();
    return strokeSignature([
      for (final r in rows) (id: r.read(t.id)!, updatedAtMs: r.read(t.updatedAt)!.millisecondsSinceEpoch),
    ]);
  }

  /// Metni kaydeder (varsa üzerine yazar, silinmişse geri getirir).
  Future<void> save({
    required String pageId,
    required String text,
    required List<TranscriptLine> lines,
    required String strokeSig,
    String languageCode = 'tr-TR',
  }) async {
    final now = _clock();
    final old = await (_db.select(_db.inkPageText)..where((r) => r.id.equals(pageId))).getSingleOrNull();
    if (old == null) {
      await _db.into(_db.inkPageText).insert(InkPageTextCompanion.insert(
            id: pageId,
            pageId: pageId,
            body: Value(text),
            linesJson: Value(TranscriptLine.encodeAll(lines)),
            languageCode: Value(languageCode),
            strokeSig: Value(strokeSig),
            recognizedAt: now,
            createdAt: now,
            updatedAt: now,
          ));
    } else {
      await (_db.update(_db.inkPageText)..where((r) => r.id.equals(pageId))).write(InkPageTextCompanion(
        body: Value(text),
        linesJson: Value(TranscriptLine.encodeAll(lines)),
        languageCode: Value(languageCode),
        strokeSig: Value(strokeSig),
        recognizedAt: Value(now),
        deleted: const Value(false),
        updatedAt: Value(now),
      ));
    }
  }

  /// Kullanıcı metni düzeltti: yalnız metin değişir (özet ve satırlar kalır).
  Future<bool> updateText(String pageId, String text) async {
    final n = await (_db.update(_db.inkPageText)..where((r) => r.id.equals(pageId) & r.deleted.equals(false)))
        .write(InkPageTextCompanion(body: Value(text), updatedAt: Value(_clock())));
    return n == 1;
  }

  Future<bool> softDelete(String pageId) async =>
      await (_db.update(_db.inkPageText)..where((r) => r.id.equals(pageId)))
          .write(InkPageTextCompanion(deleted: const Value(true), updatedAt: Value(_clock()))) ==
      1;

  Future<bool> restore(String pageId) async =>
      await (_db.update(_db.inkPageText)..where((r) => r.id.equals(pageId)))
          .write(InkPageTextCompanion(deleted: const Value(false), updatedAt: Value(_clock()))) ==
      1;

  Future<PageTextRecord?> get(String pageId) async {
    final r = await (_db.select(_db.inkPageText)..where((t) => t.id.equals(pageId) & t.deleted.equals(false)))
        .getSingleOrNull();
    return r == null ? null : _map(r);
  }

  Stream<PageTextRecord?> watch(String pageId) =>
      (_db.select(_db.inkPageText)..where((t) => t.id.equals(pageId) & t.deleted.equals(false)))
          .watchSingleOrNull()
          .map((r) => r == null ? null : _map(r));

  /// Kayıtlı metin güncel değil mi? Kayıt yoksa false.
  Future<bool> isStale(String pageId) async {
    final r = await get(pageId);
    if (r == null) return false;
    return isTextStale(storedSig: r.strokeSig, currentSig: await currentSig(pageId));
  }

  /// Tüm kayıtlı (silinmemiş) metinler: sayfa kimliği -> kayıt. Şerit rozetleri için.
  Stream<Map<String, PageTextRecord>> watchAll() =>
      (_db.select(_db.inkPageText)..where((t) => t.deleted.equals(false))).watch().map(
            (rs) => {for (final r in rs) r.pageId: _map(r)},
          );

  /// Defterin silinmemiş sayfaları sırayla, kayıtlı metniyle (yoksa null).
  Future<List<({String pageId, int pageNumber, PageTextRecord? text})>> notebookTexts(String notebookId) async {
    final pages = await _db
        .customSelect(
          'SELECT id FROM ink_note_pages WHERE notebook_id = ? AND deleted = 0 ORDER BY sort_order, created_at, id',
          variables: [Variable<String>(notebookId)],
          readsFrom: {_db.inkNotePages},
        )
        .get();
    final texts = await (_db.select(_db.inkPageText)..where((t) => t.deleted.equals(false))).get();
    final byPage = {for (final r in texts) r.pageId: _map(r)};
    final out = <({String pageId, int pageNumber, PageTextRecord? text})>[];
    for (var i = 0; i < pages.length; i++) {
      final id = pages[i].read<String>('id');
      out.add((pageId: id, pageNumber: i + 1, text: byPage[id]));
    }
    return out;
  }

  /// Defter metni değişince yeniden okunur (liste ve metin tabloları).
  /// DİKKAT: Drift akış önbelleği anahtarı yalnız SQL metni + değişkenlerdir (`readsFrom` değil);
  /// düz `SELECT 1` başka akışlarla çakışıp yanlış tabloları izletir. SQL bu yüzden benzersiz.
  Stream<List<({String pageId, int pageNumber, PageTextRecord? text})>> watchNotebookTexts(String notebookId) => _db
      .customSelect("SELECT 'hw-notebook-texts' AS k", readsFrom: {_db.inkNotePages, _db.inkPageText})
      .watch()
      .asyncMap((_) => notebookTexts(notebookId));

  /// Kayıtlı el yazısı metninde arama ([normalizeTr]; büyük/küçük harf, "İ/ı" ve
  /// aksan duyarsız). Silinmemiş defter ve sayfalarda; sonuçlar defter/sayfa sırasıyla.
  Future<List<PageTextHit>> search(String query) async {
    final q = normalizeTr(query);
    if (q.isEmpty) return const [];
    final texts = await _db
        .customSelect(
          'SELECT pt.page_id AS page_id, pt.body AS body FROM ink_page_text pt WHERE pt.deleted = 0',
          readsFrom: {_db.inkPageText},
        )
        .get();
    final matching = <String, String>{};
    for (final r in texts) {
      final body = r.read<String>('body');
      if (normalizeTr(body).contains(q)) matching[r.read<String>('page_id')] = body;
    }
    if (matching.isEmpty) return const [];
    final pages = await _db
        .customSelect(
          'SELECT p.id AS id, p.notebook_id AS nb FROM ink_note_pages p '
          'JOIN ink_notebooks n ON n.id = p.notebook_id AND n.deleted = 0 '
          'WHERE p.deleted = 0 ORDER BY n.sort_order, p.notebook_id, p.sort_order, p.created_at, p.id',
          readsFrom: {_db.inkNotePages, _db.inkNotebooks},
        )
        .get();
    final counter = <String, int>{};
    final hits = <PageTextHit>[];
    for (final r in pages) {
      final nb = r.read<String>('nb');
      final id = r.read<String>('id');
      final n = counter[nb] = (counter[nb] ?? 0) + 1;
      final body = matching[id];
      if (body != null) {
        hits.add(PageTextHit(notebookId: nb, pageId: id, pageNumber: n, snippet: _snippet(body, q)));
      }
    }
    return hits;
  }

  /// Her karakter bire bir katlanır (konum korunur): "İ" -> "i", noktalama -> boşluk.
  static String _fold1(String s) {
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final n = normalizeTr(ch);
      b.write(n.length == 1 ? n : ' ');
    }
    return b.toString();
  }

  static String _snippet(String body, String normQuery) {
    final first = normQuery.split(' ').first;
    var at = _fold1(body).indexOf(first);
    if (at < 0) at = 0;
    final from = (at - 20).clamp(0, body.length);
    final to = (at + normQuery.length + 40).clamp(0, body.length);
    final s = body.substring(from, to).replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${from > 0 ? '…' : ''}$s${to < body.length ? '…' : ''}';
  }

  PageTextRecord _map(InkPageTextRow r) => PageTextRecord(
        pageId: r.pageId,
        text: r.body,
        lines: TranscriptLine.decodeAll(r.linesJson),
        languageCode: r.languageCode,
        strokeSig: r.strokeSig,
        recognizedAt: r.recognizedAt,
        updatedAt: r.updatedAt,
      );
}
