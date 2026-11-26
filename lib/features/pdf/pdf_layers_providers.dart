import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../notes/data/note_tool_prefs_store.dart';
import 'data/pdf_layers_repository.dart';
import 'presentation/pdf_layer_state.dart';

final pdfLayersRepositoryProvider = Provider((ref) {
  return PdfLayersRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider));
});

/// Katman tercihleri (tür, numara göster): `app_meta` tek satır, cihaza özel.
final pdfLayerPrefsStoreProvider = Provider(
  (ref) => NoteToolPrefsStore(ref.watch(appDatabaseProvider), key: 'pdf.katman_ayari'),
);

/// Yuvarlak bölge düğmesinin konumu/gizli bayrağı: tüm PDF'lerde ortak.
final pdfRegionButtonStoreProvider = Provider(
  (ref) => NoteToolPrefsStore(ref.watch(appDatabaseProvider), key: 'pdf.bolge_dugmesi'),
);

/// Bir PDF'in katman durumu: üst çubuk, soldaki gezinme hapı, bölge düğmesi, küçük düğmeler ve katman
/// penceresi TEK kaynaktan okur. Okuyucu açılışta `load()` çağırır.
final pdfLayerStateProvider = Provider.family<PdfLayerState, String>((ref, documentId) {
  final s = PdfLayerState(
    documentId: documentId,
    repository: ref.watch(pdfLayersRepositoryProvider),
    prefs: ref.watch(pdfLayerPrefsStoreProvider),
    regionPrefs: ref.watch(pdfRegionButtonStoreProvider),
  );
  ref.onDispose(s.dispose);
  return s;
});
