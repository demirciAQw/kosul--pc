import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/pdf_document_record.dart';
import '../domain/pdf_import_rules.dart';

/// PDF belge deposu (T3). `id` = sha256. Silme yumuşaktır (`deleted`).
class PdfDocumentRepository {
  PdfDocumentRepository(this._db, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Ekler. Aynı sha256 varsa (silinmiş de olsa) yeni satır açmaz: satırı
  /// geri getirir, yalnızca sayfa sayısı değişmişse onu günceller; başlık, dosya adı,
  /// kitap bağı ve ofset durur. Geçersiz [sha256]'da [ArgumentError].
  Future<PdfDocumentRecord> add({
    required String sha256,
    required String title,
    required int pageCount,
    required String fileName,
  }) async {
    if (!isValidSha256(sha256)) throw ArgumentError.value(sha256, 'sha256', 'Geçersiz sha256');
    final now = _clock();
    final existing = await _row(sha256);
    if (existing == null) {
      // Eşzamanlı iki çağrıda ikincisi sessizce geçer (tek satır).
      await _db.into(_db.pdfDocuments).insert(
          PdfDocumentsCompanion.insert(
            id: sha256,
            sha256: sha256,
            title: normalizePdfTitle(title),
            pageCount: pageCount,
            fileName: fileName,
            createdAt: now,
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore);
    } else if (existing.deleted || existing.pageCount != pageCount) {
      await (_db.update(_db.pdfDocuments)..where((d) => d.id.equals(sha256))).write(PdfDocumentsCompanion(
        deleted: const Value(false),
        pageCount: Value(pageCount),
        updatedAt: Value(now),
      ));
    }
    return (await findBySha(sha256, includeDeleted: true))!;
  }

  Future<PdfDocumentRow?> _row(String sha256) =>
      (_db.select(_db.pdfDocuments)..where((d) => d.sha256.equals(sha256))).getSingleOrNull();

  Future<PdfDocumentRecord?> findBySha(String sha256, {bool includeDeleted = false}) async {
    final r = await _row(sha256);
    if (r == null || (r.deleted && !includeDeleted)) return null;
    return _toRecord(r);
  }

  Future<List<PdfDocumentRecord>> list({bool includeDeleted = false}) async {
    final q = _db.select(_db.pdfDocuments)
      ..orderBy([(d) => OrderingTerm.asc(d.title), (d) => OrderingTerm.asc(d.id)]);
    if (!includeDeleted) q.where((d) => d.deleted.equals(false));
    return [for (final r in await q.get()) _toRecord(r)];
  }

  Stream<List<PdfDocumentRecord>> watchAll() {
    final q = _db.select(_db.pdfDocuments)
      ..where((d) => d.deleted.equals(false))
      ..orderBy([(d) => OrderingTerm.asc(d.title), (d) => OrderingTerm.asc(d.id)]);
    return q.watch().map((rows) => [for (final r in rows) _toRecord(r)]);
  }

  /// Belgeyi kitaba bağlar; [bookId] null ise bağı kaldırır. Bulunamazsa false.
  Future<bool> linkBook(String id, String? bookId) => _update(id, PdfDocumentsCompanion(bookId: Value(bookId)));

  /// Kitap sayfa no = pdf sayfa no (1'den) + [offset]. Negatif olabilir
  /// (PDF'te kapak/içindekiler kitapta numarasızsa).
  Future<bool> setOffset(String id, int offset) => _update(id, PdfDocumentsCompanion(pageOffset: Value(offset)));

  Future<bool> rename(String id, String title) {
    if (title.trim().isEmpty) return Future.value(false);
    return _update(id, PdfDocumentsCompanion(title: Value(normalizePdfTitle(title))));
  }

  /// Yumuşak silme. Dosya ve çizgiler durur; yeniden içe aktarma geri getirir.
  Future<bool> softDelete(String id) => _update(id, const PdfDocumentsCompanion(deleted: Value(true)), onlyLive: true);

  Future<bool> restore(String id) => _update(id, const PdfDocumentsCompanion(deleted: Value(false)));

  Future<bool> _update(String id, PdfDocumentsCompanion c, {bool onlyLive = false}) async {
    final n = await (_db.update(_db.pdfDocuments)
          ..where((d) => onlyLive ? d.id.equals(id) & d.deleted.equals(false) : d.id.equals(id)))
        .write(c.copyWith(updatedAt: Value(_clock())));
    return n == 1;
  }

  /// Kitap eşleme önerisi için kitaplıktaki kitaplar.
  Future<List<BookCandidate>> bookCandidates() async => [
        for (final b in await _db.select(_db.books).get())
          BookCandidate(id: b.id, title: b.title, publisher: b.publisher),
      ];

  PdfDocumentRecord _toRecord(PdfDocumentRow r) => PdfDocumentRecord(
        id: r.id,
        sha256: r.sha256,
        title: r.title,
        pageCount: r.pageCount,
        fileName: r.fileName,
        bookId: r.bookId,
        pageOffset: r.pageOffset,
        deleted: r.deleted,
      );
}
