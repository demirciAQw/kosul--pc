import 'package:drift/drift.dart';

import '../../../core/database/app_database.dart';
import '../domain/board_layout.dart';
import '../domain/page_board.dart';
import 'ink_board_repository.dart';
import 'ink_notebook_repository.dart';

/// MEB konu ağacından defter üretir (v23).
///
/// Seviye kararı: ağaçtaki her düğüm (ünite ve konu) bir sayfa olur, derinlik
/// [maxDepth]'e kadar (varsayılan 1: ünite=0, konu=1; şu anki tohum ağacı en çok 2 seviyedir).
/// Daha derin düğümler (kazanımlar) sayfa olmaz; üstündeki konu sayfasına yazılır. Ağacın
/// tepesine dersin adıyla bir "kapak" sayfası konur (Pano'da kök); kapaktan ünitelere ve
/// üst konudan alt konuya `konu` bağlantıları çizilir. Sayfa başlığı = konu adı,
/// `konuId` = `curriculum_nodes.id`.
class CurriculumNotebookService {
  CurriculumNotebookService(this._db, this._notebooks, this._board);

  final AppDatabase _db;
  final InkNotebookRepository _notebooks;
  final InkBoardRepository _board;

  /// Dersin defterini oluşturur; ders [nodeId] (o düğümün dersi) ya da [examType]+[subject] ile verilir.
  /// Aynı ders için silinmemiş bir defterde zaten bu dersin konu sayfaları varsa YENİ defter
  /// açılmaz, mevcut defter döner (`created: false`): çiftleme onayı arayüzdedir.
  /// Her şey tek işlemdir. Ders ağaçta yoksa [StateError].
  Future<({String notebookId, bool created})> createNotebookFromCurriculum({
    String? nodeId,
    String? examType,
    String? subject,
    String? folderId,
    int maxDepth = 1,
  }) => _db.transaction(() async {
        final rows = await _subjectNodes(nodeId: nodeId, examType: examType, subject: subject);
        if (rows.isEmpty) throw StateError('Ders konu ağacında yok');
        final exam = rows.first.examType, ders = rows.first.subject;
        final ids = [for (final r in rows) r.id];

        final existing = await _db
            .customSelect(
              'SELECT p.notebook_id AS nb FROM ink_note_pages p JOIN ink_notebooks n ON n.id = p.notebook_id '
              'WHERE p.deleted = 0 AND n.deleted = 0 AND p.konu_id IN (${List.filled(ids.length, '?').join(',')}) '
              'ORDER BY n.created_at, n.id LIMIT 1',
              variables: [for (final i in ids) Variable<String>(i)],
              readsFrom: {_db.inkNotePages, _db.inkNotebooks},
            )
            .get();
        if (existing.isNotEmpty) return (notebookId: existing.first.read<String>('nb'), created: false);

        final chosen = [for (final r in rows) if (r.depth <= maxDepth) r];
        final chosenIds = {for (final r in chosen) r.id};
        const coverId = '\u0000ders';
        final tree = <TreeNode>[
          const TreeNode(coverId, null),
          for (final r in chosen)
            TreeNode(r.id, r.parentId != null && chosenIds.contains(r.parentId) ? r.parentId : coverId, sortOrder: r.sortOrder),
        ];
        final rects = layoutTree(tree);

        final nbId = await _notebooks.createNotebook(title: '$exam $ders', withFirstPage: false);
        if (folderId != null) await _notebooks.moveNotebookToFolder(nbId, folderId);
        final pageOf = <String, String>{};
        Future<void> page(String key, String title, String? konu) async {
          final pid = await _notebooks.addPage(nbId);
          pageOf[key] = pid;
          final r = rects[key]!;
          await _notebooks.setPageTitle(pid, title);
          await _board.setPageKonu(pid, konu);
          await _board.setBoardPositions({pid: r});
        }

        await page(coverId, '$exam $ders', null);
        for (final r in chosen) {
          await page(r.id, r.title, r.id);
        }
        for (final n in tree) {
          final parent = n.parentId;
          if (parent == null) continue;
          await _board.addLink(pageOf[parent]!, pageOf[n.id]!, kind: PageLinkKind.konu);
        }
        return (notebookId: nbId, created: true);
      });

  Future<List<CurriculumNodeRow>> _subjectNodes({String? nodeId, String? examType, String? subject}) async {
    var exam = examType, ders = subject;
    if (nodeId != null) {
      final n = await (_db.select(_db.curriculumNodes)..where((t) => t.id.equals(nodeId))).getSingleOrNull();
      if (n == null) throw StateError('Konu düğümü yok: $nodeId');
      exam = n.examType;
      ders = n.subject;
    }
    if (ders == null) throw ArgumentError('nodeId ya da subject verilmeli');
    final rows = await (_db.select(_db.curriculumNodes)
          ..where((t) => t.subject.equals(ders!) & (exam == null ? const Constant(true) : t.examType.equals(exam)))
          ..orderBy([(t) => OrderingTerm.asc(t.depth), (t) => OrderingTerm.asc(t.sortOrder), (t) => OrderingTerm.asc(t.id)]))
        .get();
    if (exam == null && rows.map((r) => r.examType).toSet().length > 1) {
      throw ArgumentError('Ders birden çok sınavda var: examType verilmeli');
    }
    return rows;
  }
}
