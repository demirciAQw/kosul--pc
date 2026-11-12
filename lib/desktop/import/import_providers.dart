import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../desktop_providers.dart';
import 'data/import_service.dart';
import 'domain/import_models.dart';

final importServiceProvider = Provider<ImportService>((ref) => ImportService(
      db: ref.watch(appDatabaseProvider),
      media: ref.watch(mediaStorageProvider),
      workDir: ref.watch(desktopDataDirProvider),
    ));

/// Son içe aktarmalar (en yenisi başta).
final importHistoryProvider =
    FutureProvider<List<ImportSummary>>((ref) => ref.watch(importServiceProvider).state.history());

/// Telefonda silinmiş, bilgisayarda duran kayıtlar.
final tombstonesProvider =
    FutureProvider<List<TombstoneView>>((ref) => ref.watch(importServiceProvider).describeTombstones());

/// Defter'de işaretlemek için: telefonda silinmiş soruların kimlikleri.
final deletedOnPhoneQuestionIdsProvider = Provider<Set<String>>((ref) => {
      for (final v in ref.watch(tombstonesProvider).value ?? const <TombstoneView>[])
        if (v.tombstone.table == 'question_cards') v.tombstone.id,
    });
