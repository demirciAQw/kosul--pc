import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/core_providers.dart';
import 'data/curriculum_notebook_service.dart';
import 'data/ink_board_repository.dart';
import 'data/ink_folder_repository.dart';
import 'data/ink_notebook_repository.dart';
import 'data/ink_page_item_repository.dart';
import 'data/page_image_store.dart';
import 'data/note_repository_impl.dart';
import 'domain/ink_folder.dart';
import 'domain/ink_notebook.dart';
import 'domain/page_board.dart';
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

// ───────────── Klasör, Pano, sayfa öğeleri (v23) ─────────────

final inkFolderRepositoryProvider =
    Provider((ref) => InkFolderRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

final inkBoardRepositoryProvider = Provider((ref) => InkBoardRepository(
      ref.watch(appDatabaseProvider),
      clock: ref.watch(clockProvider),
      notebooks: ref.watch(inkNotebookRepositoryProvider),
    ));

final inkPageItemRepositoryProvider =
    Provider((ref) => InkPageItemRepository(ref.watch(appDatabaseProvider), clock: ref.watch(clockProvider)));

final pageImageStoreProvider = Provider((ref) => PageImageStore(ref.watch(mediaStorageProvider)));

final curriculumNotebookServiceProvider = Provider((ref) => CurriculumNotebookService(
      ref.watch(appDatabaseProvider),
      ref.watch(inkNotebookRepositoryProvider),
      ref.watch(inkBoardRepositoryProvider),
    ));

/// Silinmemiş klasörler (her biri doğrudan defter sayısıyla).
final inkFoldersProvider =
    StreamProvider.autoDispose<List<InkFolderRecord>>((ref) => ref.watch(inkFolderRepositoryProvider).watchFolders());

final boardCardsProvider = StreamProvider.autoDispose.family<List<BoardCard>, String>(
    (ref, notebookId) => ref.watch(inkBoardRepositoryProvider).watchBoardCards(notebookId));

final boardLinksProvider = StreamProvider.autoDispose.family<List<PageLinkRecord>, String>(
    (ref, notebookId) => ref.watch(inkBoardRepositoryProvider).watchLinks(notebookId));

final pageItemsProvider = StreamProvider.autoDispose.family<List<PageItemRecord>, String>(
    (ref, pageId) => ref.watch(inkPageItemRepositoryProvider).watchItems(pageId));
