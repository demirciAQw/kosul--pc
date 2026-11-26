import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import '../ocr/auto_tag_providers.dart';
import 'data/anlik_repository_impl.dart';
import 'domain/anlik.dart';
import 'domain/anlik_repository.dart';
import 'domain/anlik_search.dart';
import 'domain/save_anlik.dart';

final anlikRepositoryProvider =
    Provider<AnlikRepository>((ref) => DriftAnlikRepository(ref.watch(appDatabaseProvider)));

/// Konu sözlüğü yüklenince otomatik etiket çalışır; yüklenmeden de kayıt olur.
final saveAnlikProvider = Provider((ref) => SaveAnlik(
      ref.watch(anlikRepositoryProvider),
      ref.watch(idGeneratorProvider),
      ref.watch(clockProvider),
      lexicon: ref.watch(topicLexiconProvider).value,
    ));

final anlikNotesProvider = StreamProvider<List<AnlikNote>>((ref) => ref.watch(anlikRepositoryProvider).watchNotes());
final tagsProvider = StreamProvider<List<Tag>>((ref) => ref.watch(anlikRepositoryProvider).watchTags());
final peopleProvider = StreamProvider<List<Person>>((ref) => ref.watch(anlikRepositoryProvider).watchPeople());
final cardTagsProvider =
    StreamProvider<Map<String, Set<String>>>((ref) => ref.watch(anlikRepositoryProvider).watchCardTags());

class AnlikFilterNotifier extends Notifier<AnlikFilter> {
  @override
  AnlikFilter build() => const AnlikFilter();
  void set(AnlikFilter f) => state = f;
  void clear() => state = const AnlikFilter();
}

final anlikFilterProvider = NotifierProvider<AnlikFilterNotifier, AnlikFilter>(AnlikFilterNotifier.new);

/// Süzülmüş liste, en yeni başta.
final filteredAnlikProvider = Provider<AsyncValue<List<AnlikNote>>>((ref) {
  final f = ref.watch(anlikFilterProvider);
  final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
  return ref.watch(anlikNotesProvider).whenData((notes) => filterAnlik(notes, f, tags: tags));
});

/// Son uyku kaydı yattım ise sıradaki düğme "Kalktım" olur.
final sleepIsAwakeProvider = Provider<bool>((ref) {
  final notes = ref.watch(anlikNotesProvider).value ?? const <AnlikNote>[];
  final sleep = [for (final n in notes) if (n.isSleep) n]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return sleep.isEmpty || sleep.first.kind == AnlikKind.kalktim; // uyanığız → "Yattım"
});
