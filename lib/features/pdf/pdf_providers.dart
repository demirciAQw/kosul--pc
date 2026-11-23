import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/di/core_providers.dart';
import '../../app/platform.dart';
import '../ink/data/ink_stroke_repository.dart';
import '../ocr/auto_tag_providers.dart';
import '../ocr/data/ocr_queue.dart' show OcrQueue;
import '../ocr/ocr_providers.dart';
import '../library/library_providers.dart';
import '../question_bank/domain/question_card.dart';
import '../question_bank/question_bank_providers.dart';
import 'data/pdf_document_repository.dart';
import 'data/pdf_import_service.dart';
import 'data/pdf_question_service.dart';
import 'data/pdfrx_engine.dart';
import 'domain/book_analysis.dart';
import 'domain/pdf_document_record.dart';
import 'domain/pdf_engine.dart';
import 'domain/solve.dart';
import 'pdf_layers_providers.dart';

final pdfEngineProvider = Provider<PdfEngine>((ref) => const PdfrxEngine());

final pdfDocumentRepositoryProvider =
    Provider((ref) => PdfDocumentRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

final pdfImportServiceProvider = FutureProvider<PdfImportService>((ref) async {
  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'pdfs'));
  return PdfImportService(
    engine: ref.watch(pdfEngineProvider),
    repository: ref.watch(pdfDocumentRepositoryProvider),
    pdfDir: dir,
  );
});

/// Sorunun deneme listesi (çizgi zamanlarından: deneme no, çizgi sayısı, süre).
final solveAttemptsProvider = StreamProvider.autoDispose.family<List<SolveAttempt>, String>(
    (ref, questionId) => ref.watch(inkStrokeRepositoryProvider).watchSolveTimes(questionId).map(solveAttempts));

/// Galeri işareti için tüm soruların çözüm özeti (tek sorgu).
final solveSummariesProvider = StreamProvider<Map<String, SolveSummary>>(
    (ref) => ref.watch(inkStrokeRepositoryProvider).watchAllSolveTimes().map(solveSummaries));

final inkStrokeRepositoryProvider =
    Provider((ref) => InkStrokeRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

/// Okuyucunun açacağı belge: kayıt ve (bu cihazda varsa) dosya yolu.
class PdfOpenInfo {
  const PdfOpenInfo(this.record, this.path);
  final PdfDocumentRecord record;

  /// Dosya bu cihazda yoksa null (satır başka cihazdan gelmiştir).
  final String? path;
}

final pdfOpenInfoProvider = FutureProvider.family<PdfOpenInfo?, String>((ref, id) async {
  final record = await ref.watch(pdfDocumentRepositoryProvider).findBySha(id);
  if (record == null) return null;
  final svc = await ref.watch(pdfImportServiceProvider.future);
  final f = svc.fileOf(record);
  return PdfOpenInfo(record, f.existsSync() ? f.path : null);
});

final pdfDocumentsProvider =
    StreamProvider<List<PdfDocumentRecord>>((ref) => ref.watch(pdfDocumentRepositoryProvider).watchAll());

/// PDF seçici (testte değiştirilir). Seçilmezse null.
final pdfPickerProvider = Provider<Future<File?> Function()>((ref) => () async {
      final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
      final path = res?.files.single.path;
      return path == null ? null : File(path);
    });

/// "Soru seç" aracının servisi. ML Kit yalnızca Android'de verilir
/// (Linux'ta taranmış PDF kutusu metinsiz kaydedilir).
final pdfQuestionServiceProvider = FutureProvider<PdfQuestionService>((ref) async {
  return PdfQuestionService(
    engine: ref.watch(pdfEngineProvider),
    cards: ref.watch(questionCardRepositoryProvider),
    media: ref.watch(mediaStorageProvider),
    ids: ref.watch(idGeneratorProvider),
    clock: ref.watch(clockProvider),
    tempDir: await getTemporaryDirectory(),
    lexicon: () => ref.read(topicLexiconProvider.future),
    ocr: isAndroid ? ref.watch(ocrEngineProvider) : null,
    ocrRepository: ref.watch(ocrRepositoryProvider),
    ocrEngineVersion: OcrQueue.engineVersion,
    layers: ref.watch(pdfLayersRepositoryProvider),
  );
});

/// Kartın PDF'i bu cihazda var mı (dokununca PDF'e gidilir, yoksa yalnız önizleme).
final pdfAvailableProvider = FutureProvider.autoDispose.family<bool, String>((ref, id) async {
  // Belge eklenince/silinince yeniden hesaplansın.
  await ref.watch(pdfDocumentsProvider.future);
  final record = await ref.watch(pdfDocumentRepositoryProvider).findBySha(id);
  if (record == null) return false;
  final svc = await ref.watch(pdfImportServiceProvider.future);
  return svc.fileOf(record).exists();
});

/// Kitaba bağlı (silinmemiş) ilk PDF; yoksa null. Kitap ekranları "PDF'te aç"ı buna bakıp gösterir.
final pdfForBookProvider = Provider.family<PdfDocumentRecord?, String>((ref, bookId) {
  final docs = ref.watch(pdfDocumentsProvider).value ?? const <PdfDocumentRecord>[];
  return docs.where((d) => d.bookId == bookId && !d.deleted).firstOrNull;
});

/// Kitabın tüm soru kartları (doğru/yanlış/boş) — analiz modu için.
final _bookCardsProvider = StreamProvider.autoDispose.family<List<QuestionCard>, String>(
    (ref, bookId) => ref.watch(questionCardRepositoryProvider).watch(QuestionFilter(bookId: bookId)));

/// Analiz modu verisi: PDF'in bağlı olduğu kitabın haritası + kartları.
/// PDF kitaba bağlı değilse ya da kitap yoksa `AsyncData(null)`.
final bookAnalysisProvider = Provider.autoDispose.family<AsyncValue<BookAnalysis?>, String>((ref, docId) {
  final info = ref.watch(pdfOpenInfoProvider(docId));
  final record = info.value?.record;
  final bookId = record?.bookId;
  if (record == null || bookId == null) {
    return info.isLoading ? const AsyncLoading() : const AsyncData(null);
  }
  final books = ref.watch(libraryProvider);
  final cards = ref.watch(_bookCardsProvider(bookId));
  final book = ref.watch(bookByIdProvider(bookId));
  if (book == null) return books.isLoading ? const AsyncLoading() : const AsyncData(null);
  if (cards.hasError) return AsyncError(cards.error!, cards.stackTrace ?? StackTrace.empty);
  if (!cards.hasValue) return const AsyncLoading();
  return AsyncData(buildBookAnalysis(book: book, doc: record, cards: cards.requireValue));
});
