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
import '../question_bank/question_bank_providers.dart';
import 'data/pdf_document_repository.dart';
import 'data/pdf_import_service.dart';
import 'data/pdf_question_service.dart';
import 'data/pdfrx_engine.dart';
import 'domain/pdf_document_record.dart';
import 'domain/pdf_engine.dart';

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
