import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import 'data/pdf_layers_repository.dart';

final pdfLayersRepositoryProvider = Provider((ref) {
  final repo = PdfLayersRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider));
  ref.onDispose(repo.dispose);
  return repo;
});
