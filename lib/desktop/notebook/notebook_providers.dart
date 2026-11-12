import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/curriculum/curriculum_providers.dart';
import '../../features/curriculum/domain/curriculum.dart';
import '../../features/library/domain/library.dart';
import '../../features/library/library_providers.dart';
import '../../features/ocr/auto_tag_providers.dart';
import '../../features/ocr/domain/ocr.dart';
import '../../features/ocr/ocr_providers.dart';
import '../../features/question_bank/domain/question_card.dart';
import '../../features/question_bank/question_bank_providers.dart';
import '../import/import_providers.dart';
import 'domain/notebook_table.dart';

/// Defterin tüm satırları: kart + konu, kaynak, okunan metin, telefonda silindi mi.
final notebookRowsProvider = Provider<AsyncValue<List<NotebookRow>>>((ref) {
  final cards = ref.watch(allQuestionsProvider);
  final curriculum = {for (final n in ref.watch(curriculumProvider).value ?? const <CurriculumNode>[]) n.id: n};
  final books = {for (final b in ref.watch(libraryProvider).value ?? const <Book>[]) b.id: b};
  final records = ref.watch(ocrRecordsProvider).value ?? const <String, OcrRecord>{};
  final tags = ref.watch(autoTagsProvider);
  final deleted = ref.watch(deletedOnPhoneQuestionIdsProvider);
  return cards.whenData((list) {
    final fallback = fallbackTopicsFor(list, tags);
    return [
      for (final c in list)
        NotebookRow(
          card: c,
          topic: (c.mebNodeId == null ? null : curriculum[c.mebNodeId]?.title) ?? fallback[c.id] ?? '',
          source: (c.bookId == null ? null : books[c.bookId]?.title) ?? c.sourceName,
          searchable: _searchable(records[OcrJob.questionId(c.id)]),
          deletedOnPhone: deleted.contains(c.id),
        ),
    ];
  });
});

String _searchable(OcrRecord? r) => r != null && r.ok ? r.searchable : '';

class NotebookQueryNotifier extends Notifier<NotebookQuery> {
  @override
  NotebookQuery build() => const NotebookQuery();

  void set(NotebookQuery q) => state = q;
}

final notebookQueryProvider = NotifierProvider<NotebookQueryNotifier, NotebookQuery>(NotebookQueryNotifier.new);

/// Ekrandaki (filtrelenmiş, sıralanmış) satırlar.
final notebookVisibleRowsProvider = Provider<List<NotebookRow>>((ref) {
  final rows = ref.watch(notebookRowsProvider).value ?? const <NotebookRow>[];
  return applyNotebookQuery(rows, ref.watch(notebookQueryProvider));
});

class NotebookSelection extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) => state = id;
}

/// Seçili sorunun kimliği.
final notebookSelectionProvider = NotifierProvider<NotebookSelection, String?>(NotebookSelection.new);

/// Filtre seçenekleri: dersler, kaynaklar, nedenler (yalnızca kullanılanlar).
final notebookOptionsProvider =
    Provider<({List<String> subjects, List<String> sources, List<MistakeReason> reasons})>((ref) {
  final rows = ref.watch(notebookRowsProvider).value ?? const <NotebookRow>[];
  final subjects = {for (final r in rows) r.card.subject}.toList()..sort();
  final sources = {for (final r in rows) r.source}.toList()..sort();
  final used = {
    for (final r in rows)
      if (r.card.reason case final m?) m,
  };
  return (
    subjects: subjects,
    sources: sources,
    reasons: [for (final m in MistakeReason.values) if (used.contains(m)) m],
  );
});
