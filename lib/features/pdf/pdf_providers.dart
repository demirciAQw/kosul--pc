import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/di/core_providers.dart';
import 'data/pdf_document_repository.dart';
import 'data/pdf_import_service.dart';
import 'data/pdfrx_engine.dart';
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
