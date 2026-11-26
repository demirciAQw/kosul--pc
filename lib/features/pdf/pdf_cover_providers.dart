import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/pdf_cover_store.dart';
import 'domain/pdf_import_rules.dart' show storedFileName;
import 'pdf_providers.dart';

final pdfCoverStoreProvider = FutureProvider<PdfCoverStore>((ref) async {
  final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'pdf_kapak'));
  return PdfCoverStore(engine: ref.watch(pdfEngineProvider), dir: dir);
});

/// PDF'in 1. sayfa kapak dosyası (belge sha256'sı ile); yoksa tembelce üretilir, başarısızsa null.
final pdfCoverFileProvider = FutureProvider.family<File?, String>((ref, sha) async {
  final svc = await ref.watch(pdfImportServiceProvider.future);
  final store = await ref.watch(pdfCoverStoreProvider.future);
  return store.coverFor(sha, File(p.join(svc.pdfDir.path, storedFileName(sha))));
});
