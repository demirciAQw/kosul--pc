/// Veritabanındaki PDF belgesinin saf Dart karşılığı.
library;

class PdfDocumentRecord {
  const PdfDocumentRecord({
    required this.id,
    required this.sha256,
    required this.title,
    required this.pageCount,
    required this.fileName,
    this.bookId,
    this.pageOffset = 0,
    this.deleted = false,
  });

  /// `sha256` ile aynıdır (iki cihazda aynı PDF aynı satır).
  final String id;
  final String sha256;
  final String title;
  final int pageCount;
  final String fileName;
  final String? bookId;
  final int pageOffset;
  final bool deleted;

  /// PDF sayfası (0'dan) → kitap sayfa numarası. Kitap sayfası 1'den başlar.
  int bookPageOf(int pdfPage) => pdfPage + 1 + pageOffset;

  /// Kitap sayfa numarası → PDF sayfası (0'dan); aralık dışıysa null.
  int? pdfPageOf(int bookPage) {
    final p = bookPage - 1 - pageOffset;
    return p >= 0 && p < pageCount ? p : null;
  }
}
