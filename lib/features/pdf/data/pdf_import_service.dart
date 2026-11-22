import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../domain/pdf_document_record.dart';
import '../domain/pdf_engine.dart';
import '../domain/pdf_import_rules.dart';
import 'pdf_document_repository.dart';

class PdfImportResult {
  const PdfImportResult({required this.document, required this.alreadyImported, required this.suggestions});
  final PdfDocumentRecord document;

  /// Aynı sha256 daha önce eklenmişti (dosya yeniden kopyalanmadı).
  final bool alreadyImported;

  /// Kitaplık eşleme önerisi. Bağlama YAPILMAZ; arayüz sorar (`repo.linkBook`).
  /// Belge zaten bir kitaba bağlıysa boştur.
  final List<BookSuggestion> suggestions;
}

/// PDF'i uygulama veri klasörüne `pdfs/<sha256>.pdf` olarak alır.
/// IO ince katmandır; kurallar `pdf_import_rules.dart`'ta.
class PdfImportService {
  PdfImportService({required this.engine, required this.repository, required this.pdfDir});

  final PdfEngine engine;
  final PdfDocumentRepository repository;

  /// `<veri klasörü>/pdfs`
  final Directory pdfDir;

  /// Saklanan dosyanın yolu (belge satırı başka cihazdan gelmişse dosya olmayabilir).
  File fileOf(PdfDocumentRecord d) => File(p.join(pdfDir.path, storedFileName(d.sha256)));

  bool hasFile(PdfDocumentRecord d) => fileOf(d).existsSync();

  static Future<String> sha256OfFile(File f) async => (await crypto.sha256.bind(f.openRead()).first).toString();

  /// Bozuksa [PdfOpenException]; o durumda klasörde dosya kalmaz.
  Future<PdfImportResult> importFile(File source, {String? title}) async {
    final sha = await sha256OfFile(source);
    final target = File(p.join(pdfDir.path, storedFileName(sha)));

    final existing = await repository.findBySha(sha);
    if (existing != null && target.existsSync()) {
      return PdfImportResult(document: existing, alreadyImported: true, suggestions: await _suggest(existing));
    }

    // Satır var ama dosya bu cihazda yok (başka cihazdan geldi) ya da hiç yok:
    // dosyayı yaz, satırı ekle/geri getir.
    await pdfDir.create(recursive: true);
    final tmp = File('${target.path}.part');
    try {
      await source.copy(tmp.path);
      final doc = await engine.openFile(tmp.path);
      final int pages;
      try {
        pages = doc.pageCount;
      } finally {
        await doc.close();
      }
      if (pages <= 0) throw const PdfOpenException('Sayfa yok');
      await tmp.rename(target.path);
      final fileName = p.basename(source.path);
      final record = await repository.add(
        sha256: sha,
        title: title ?? titleFromFileName(fileName),
        pageCount: pages,
        fileName: fileName,
      );
      return PdfImportResult(
        document: record,
        alreadyImported: existing != null,
        suggestions: await _suggest(record),
      );
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  Future<List<BookSuggestion>> _suggest(PdfDocumentRecord d) async =>
      d.bookId != null ? const [] : suggestBooks(d.title, await repository.bookCandidates());
}
