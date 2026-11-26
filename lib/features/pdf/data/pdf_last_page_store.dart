import '../../../core/database/app_database.dart';

/// PDF'in en son bırakıldığı sayfa (0'dan): `app_meta` `pdf.son_sayfa.<pdfId>`.
/// Cihaza özeldir (okuma konumu); yedekle birleşmez, çizgi/kart verisine dokunmaz.
class PdfLastPageStore {
  PdfLastPageStore(this._db);
  final AppDatabase _db;

  static String keyFor(String documentId) => 'pdf.son_sayfa.$documentId';

  /// Kayıtlı sayfa; yok, bozuk ya da negatifse null.
  Future<int?> load(String documentId) async {
    try {
      final row = await (_db.select(_db.appMeta)..where((m) => m.metaKey.equals(keyFor(documentId)))).getSingleOrNull();
      final v = int.tryParse(row?.metaValue ?? '');
      return v != null && v >= 0 ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String documentId, int page) async {
    if (page < 0) return;
    try {
      await _db
          .into(_db.appMeta)
          .insertOnConflictUpdate(AppMetaCompanion.insert(metaKey: keyFor(documentId), metaValue: '$page'));
    } catch (_) {
      // veritabanı kapanmış olabilir: konum kaybı veri kaybı değildir
    }
  }
}

/// Açılış sayfası (0'dan): bağlantıyla gelen geçerli sayfa önce, sonra kayıtlı son sayfa, yoksa başa (null).
int? startPage({required int? linked, required int? saved, required int pageCount}) {
  if (linked != null && linked >= 0 && linked < pageCount) return linked;
  if (saved != null && saved >= 0 && saved < pageCount) return saved;
  return null;
}
