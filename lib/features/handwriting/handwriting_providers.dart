import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/platform.dart';
import '../../core/di/core_providers.dart';
import '../notes/notes_providers.dart' show inkNotebooksProvider;
import '../pdf/pdf_providers.dart' show inkStrokeRepositoryProvider;
import 'data/handwriting_service.dart';
import 'data/mlkit_handwriting_recognizer.dart';
import 'data/page_text_repository.dart';
import 'domain/handwriting_recognizer.dart';

/// Tanıyıcı: yalnız Android'de ML Kit; masaüstünde eklentiye hiç dokunulmaz.
final handwritingRecognizerProvider = Provider<HandwritingRecognizer>((ref) {
  if (!isAndroid) return const UnsupportedHandwritingRecognizer();
  final r = MlKitHandwritingRecognizer();
  ref.onDispose(r.close);
  return r;
});

final pageTextRepositoryProvider =
    Provider((ref) => PageTextRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

final handwritingServiceProvider = Provider((ref) => HandwritingService(
      ref.watch(handwritingRecognizerProvider),
      ref.watch(inkStrokeRepositoryProvider),
      ref.watch(pageTextRepositoryProvider),
    ));

/// Bu cihazda tanıma düğmeleri gösterilsin mi (masaüstünde hayır; kayıtlı metin yine görünür).
final handwritingAvailableProvider = Provider<bool>((ref) => ref.watch(handwritingRecognizerProvider).isSupported);

/// Sayfa kimliği -> kayıtlı metin (şerit rozetleri, arama).
final pageTextsProvider = StreamProvider.autoDispose<Map<String, PageTextRecord>>(
    (ref) => ref.watch(pageTextRepositoryProvider).watchAll());

final pageTextProvider = StreamProvider.autoDispose.family<PageTextRecord?, String>(
    (ref, pageId) => ref.watch(pageTextRepositoryProvider).watch(pageId));

/// Defterin sayfaları + kayıtlı metinleri (metin kopyası ekranı).
final notebookTextsProvider = StreamProvider.autoDispose
    .family<List<({String pageId, int pageNumber, PageTextRecord? text})>, String>(
        (ref, notebookId) => ref.watch(pageTextRepositoryProvider).watchNotebookTexts(notebookId));

/// Defter listesi araması: kayıtlı metinde eşleşen sayfalar (boş sorguda boş).
final pageTextSearchProvider = FutureProvider.autoDispose.family<List<PageTextHit>, String>((ref, query) async {
  // Defter/sayfa/metin değişince yeniden aranır.
  ref.watch(inkNotebooksProvider);
  ref.watch(pageTextsProvider);
  return ref.watch(pageTextRepositoryProvider).search(query);
});

/// Model durumu ve indirme/silme işlemi (Ayarlar kartı, "Sayfayı metne çevir" önerisi).
class HandwritingModelState {
  const HandwritingModelState({
    this.status,
    this.busy = false,
    this.error,
  });

  /// null: henüz sorulmadı.
  final HandwritingModelStatus? status;

  /// İndirme ya da silme sürüyor.
  final bool busy;
  final String? error;
}

class HandwritingModelController extends Notifier<HandwritingModelState> {
  int _token = 0;

  @override
  HandwritingModelState build() {
    scheduleMicrotask(refresh);
    return const HandwritingModelState();
  }

  HandwritingRecognizer get _r => ref.read(handwritingRecognizerProvider);

  Future<void> refresh() async {
    final s = await _r.modelStatus();
    state = HandwritingModelState(status: s, busy: state.busy, error: state.error);
  }

  /// ML Kit indirmeyi dışarıdan iptal ettirmez ve ilerleme bildirmez: "iptal" yalnızca
  /// beklemeyi bırakır (indirme arka planda bitebilir; durum yeniden sorulur).
  Future<bool> download({bool wifiOnly = false}) async {
    final my = ++_token;
    state = HandwritingModelState(status: state.status, busy: true);
    try {
      await _r.downloadModel(wifiOnly: wifiOnly);
      if (my != _token) return false;
      state = const HandwritingModelState(status: HandwritingModelStatus.downloaded);
      return true;
    } on HandwritingException catch (e) {
      if (my == _token) state = HandwritingModelState(status: state.status, error: e.message);
      return false;
    }
  }

  void cancelWaiting() {
    _token++;
    state = HandwritingModelState(status: state.status);
    unawaited(refresh());
  }

  Future<void> delete() async {
    state = HandwritingModelState(status: state.status, busy: true);
    try {
      await _r.deleteModel();
      state = const HandwritingModelState(status: HandwritingModelStatus.notDownloaded);
    } on HandwritingException catch (e) {
      state = HandwritingModelState(status: state.status, error: e.message);
    }
  }
}

final handwritingModelProvider =
    NotifierProvider<HandwritingModelController, HandwritingModelState>(HandwritingModelController.new);

/// Kayıtlı metni olup çizgisi sonradan değişen sayfalar (defter metin kopyası ekranı).
final staleTextPagesProvider = FutureProvider.autoDispose.family<Set<String>, String>((ref, notebookId) async {
  final entries = await ref.watch(notebookTextsProvider(notebookId).future);
  final repo = ref.watch(pageTextRepositoryProvider);
  return {
    for (final e in entries)
      if (e.text != null && await repo.isStale(e.pageId)) e.pageId,
  };
});
