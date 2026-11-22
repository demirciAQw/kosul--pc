import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import 'data/ink_notebook_repository.dart';
import 'data/note_repository_impl.dart';
import 'domain/ink_notebook.dart';
import 'domain/notes.dart';

final noteRepositoryProvider = Provider<NoteRepository>((ref) => DriftNoteRepository(ref.watch(appDatabaseProvider)));

final saveNoteProvider = Provider((ref) => SaveNote(
      ref.watch(noteRepositoryProvider),
      ref.watch(idGeneratorProvider),
      ref.watch(clockProvider),
      ref.watch(mediaStorageProvider),
    ));

final deleteNoteProvider =
    Provider((ref) => DeleteNote(ref.watch(noteRepositoryProvider), ref.watch(mediaStorageProvider)));

final notesProvider = StreamProvider<List<StudyNote>>((ref) => ref.watch(noteRepositoryProvider).watchAll());

/// Notlar sekmesinde seçili ders (null = tüm dersler).
class NoteSubjectFilter extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? subject) => state = subject;
}

final noteSubjectFilterProvider = NotifierProvider<NoteSubjectFilter, String?>(NoteSubjectFilter.new);

/// Kalemli defterler (tablet T6). Ders/Anlık notlarından ayrıdır.
final inkNotebookRepositoryProvider =
    Provider((ref) => InkNotebookRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

/// Silinenler dahil tüm defterler; ekran süzer (geri alma listesi için).
final inkNotebooksProvider = StreamProvider.autoDispose<List<InkNotebookRecord>>(
    (ref) => ref.watch(inkNotebookRepositoryProvider).watchNotebooks(includeDeleted: true));

final inkNotebookPagesProvider = StreamProvider.autoDispose.family<List<InkNotePageRecord>, String>(
    (ref, notebookId) => ref.watch(inkNotebookRepositoryProvider).watchPages(notebookId));

/// Defter → etiketler (kendi + sayfa etiketleri); liste çipleri ve süzme için.
final inkNotebookTagMapProvider = StreamProvider.autoDispose<Map<String, Set<String>>>(
    (ref) => ref.watch(inkNotebookRepositoryProvider).watchNotebookTagMap());
