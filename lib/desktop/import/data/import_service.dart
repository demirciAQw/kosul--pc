import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/export/zip_reader.dart';
import '../../../core/media/media_storage.dart';
import '../domain/import_models.dart';
import '../domain/import_rules.dart';
import 'backup_source.dart';
import 'desktop_state_store.dart';
import 'snapshot_merger.dart';

/// İçe aktarmaya hazır yedek: veritabanı kopyası geçici klasöre çıkarılmış,
/// tarih denetimi yapılmış. Kullanıcı onaylarsa [ImportService.run],
/// vazgeçerse [ImportService.discard].
class PreparedImport {
  PreparedImport._({
    required this.source,
    required this.database,
    required this.json,
    required this.exportedAt,
    required this.lastImported,
  });

  final BackupSource source;
  final File database;
  final List<int>? json;
  final DateTime? exportedAt;
  final DateTime? lastImported;

  /// Son içe aktarılandan eski bir yedek mi? (Önce sorulur.)
  bool get isOlder => isOlderBackup(exportedAt, lastImported);
  String get label => source.label;
}

/// Telefon yedeğini bilgisayara alır: veritabanını birleştirir, fotoğrafları
/// kopyalar, "telefonda silindi" listesini günceller, koç klasörüne yazar.
class ImportService {
  ImportService({
    required AppDatabase db,
    required MediaStorage media,
    required Directory workDir,
    DateTime Function()? now,
  })  : _db = db,
        _media = media,
        _workDir = workDir,
        _now = now ?? DateTime.now,
        state = DesktopStateStore(db);

  final AppDatabase _db;
  final MediaStorage _media;
  final Directory _workDir;
  final DateTime Function() _now;
  final DesktopStateStore state;

  Future<PreparedImport> prepare(String path) async {
    final source = await BackupSource.open(path);
    try {
      final json = await source.readJson();
      final decoded = _decode(json);
      if (json != null && decoded?['format'] != 'kocum.backup') {
        throw const ImportException('Bu bir Koçum yedeği değil.');
      }
      final database = File(p.join(_workDir.path, 'ice_aktarma', 'kocum_${_now().microsecondsSinceEpoch}.db'));
      if (!await source.extractDatabase(database)) {
        throw const ImportException('Bu yedekte veritabanı kopyası (kocum.db) yok. Telefona Koçum 8.5 ya da '
            'sonrasını kur ve Araçlar → Tüm veriyi dışa aktar ile yeni bir yedek al.');
      }
      return PreparedImport._(
        source: source,
        database: database,
        json: json,
        exportedAt: exportedAtOf(decoded),
        lastImported: await state.lastExportedAt(),
      );
    } catch (_) {
      await source.close();
      rethrow;
    }
  }

  Future<ImportSummary> run(PreparedImport job, {bool automatic = false}) async {
    try {
      final tables = await SnapshotMerger(_db).merge(job.database);
      final photos = await _copyMedia(job.source);
      final now = _now();
      await state.saveTombstones(updateTombstones(
        await state.tombstones(),
        {for (final t in tables) t.table: t.missingIds},
        now,
      ));
      // Eski bir yedek bilerek alınsa da "son yedek" tarihi geri gitmez.
      final exported = job.exportedAt;
      final last = job.lastImported;
      if (exported != null && (last == null || exported.isAfter(last))) await state.setLastExportedAt(exported);

      final warnings = <String>[
        if (photos.rejected > 0) '${photos.rejected} fotoğrafın adı güvenli değildi, alınmadı.',
      ];
      try {
        await _writeCoachCopy(job.json);
      } on FileSystemException catch (e) {
        warnings.add('Koç klasörüne yazılamadı: ${e.message} (${e.path ?? ''})');
      }
      final summary = ImportSummary(
        at: now,
        source: job.label,
        exportedAt: exported,
        tables: tables,
        photosAdded: photos.added,
        photosSkipped: photos.skipped,
        photosRejected: photos.rejected,
        automatic: automatic,
        warnings: warnings,
      );
      await state.addHistory(summary);
      return summary;
    } finally {
      await discard(job);
    }
  }

  Future<void> discard(PreparedImport job) async {
    await job.source.close();
    try {
      if (await job.database.exists()) await job.database.delete();
    } on FileSystemException {
      // Geçici dosya; silinemezse bir sonraki içe aktarmayı etkilemez.
    }
  }

  /// Fotoğraflar değişmez (her biri benzersiz adlı); aynı boyutta olan atlanır.
  Future<({int added, int skipped, int rejected})> _copyMedia(BackupSource source) async {
    var added = 0, skipped = 0, rejected = 0;
    for (final e in (await source.mediaFiles()).entries) {
      if (!isSafeZipPath(e.key)) {
        rejected++;
        continue;
      }
      final target = _media.resolve(e.key);
      if (await target.exists() && await target.length() == e.value) {
        skipped++;
        continue;
      }
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await source.readMedia(e.key), flush: true);
      added++;
    }
    return (added: added, skipped: skipped, rejected: rejected);
  }

  /// Koç klasörü seçiliyse güncel yedek JSON'u (fotoğrafsız) "<klasör>/Koçum/"
  /// altına yazılır; yarım dosya oluşmasın diye önce geçici ada.
  Future<void> _writeCoachCopy(List<int>? json) async {
    final folder = await state.coachFolder();
    if (folder == null || json == null) return;
    final dir = Directory(p.join(folder, 'Koçum'));
    await dir.create(recursive: true);
    final target = File(p.join(dir.path, backupJsonName));
    final temp = File('${target.path}.yaziliyor');
    await temp.writeAsBytes(json, flush: true);
    await temp.rename(target.path);
  }

  // ───────────── Telefonda silinenler ─────────────

  /// Ekran için açıklamalarıyla; elle silinmiş (artık olmayan) kayıtlar
  /// listeden düşer.
  Future<List<TombstoneView>> describeTombstones() async {
    final all = await state.tombstones();
    final views = <TombstoneView>[];
    for (final group in _byTable(all).entries) {
      final key = _primaryKey(group.key);
      if (key == null) continue;
      final label = _labelSql[group.key] ?? '"$key"';
      final labels = <String, String>{};
      for (final chunk in _chunks(group.value.map((t) => t.id).toList())) {
        final rows = await _db.customSelect(
          'SELECT "$key" AS id, CAST($label AS TEXT) AS label FROM "${group.key}" '
          'WHERE "$key" IN (${List.filled(chunk.length, '?').join(', ')})',
          variables: [for (final id in chunk) Variable.withString(id)],
        ).get();
        for (final r in rows) {
          labels[r.read<String>('id')] = r.readNullable<String>('label') ?? r.read<String>('id');
        }
      }
      for (final t in group.value) {
        final l = labels[t.id];
        if (l != null) views.add(TombstoneView(t, l));
      }
    }
    if (views.length != all.length) await state.saveTombstones([for (final v in views) v.tombstone]);
    return views;
  }

  /// Kullanıcının onayıyla siler. Bağlı kayıtlar veritabanı kurallarıyla gider
  /// (ör. kitap silinince testleri ve sonuçları).
  Future<void> deleteTombstoned(Iterable<Tombstone> items) async {
    await _db.transaction(() async {
      for (final group in _byTable(items).entries) {
        final key = _primaryKey(group.key);
        if (key == null) continue;
        for (final chunk in _chunks(group.value.map((t) => t.id).toList())) {
          await _db.customStatement(
            'DELETE FROM "${group.key}" WHERE "$key" IN (${List.filled(chunk.length, '?').join(', ')})',
            chunk,
          );
        }
      }
    });
    _db.notifyUpdates({for (final t in _db.allTables) TableUpdate.onTable(t)});
    await describeTombstones(); // zincirleme silinenler de listeden düşer
  }

  String? _primaryKey(String table) {
    for (final t in _db.allTables) {
      if (t.actualTableName == table) return t.$primaryKey.single.$name;
    }
    return null;
  }

  static Map<String, List<Tombstone>> _byTable(Iterable<Tombstone> items) {
    final out = <String, List<Tombstone>>{};
    for (final t in items) {
      (out[t.table] ??= []).add(t);
    }
    return out;
  }

  static Iterable<List<String>> _chunks(List<String> ids, [int size = 400]) sync* {
    for (var i = 0; i < ids.length; i += size) {
      yield ids.sublist(i, i + size > ids.length ? ids.length : i + size);
    }
  }

  static Map<String, Object?>? _decode(List<int>? json) {
    if (json == null) return null;
    try {
      final v = jsonDecode(utf8.decode(json));
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// Silinen kaydın ekrandaki adı (tablo başına SQL ifadesi).
const _labelSql = <String, String>{
  'question_cards':
      "subject || ' · ' || COALESCE(test_label, source_name) || COALESCE(' · ' || question_no || '. soru', '')",
  'books': 'title',
  'content_nodes': 'title',
  'test_results':
      'COALESCE((SELECT c.title FROM content_nodes c WHERE c.id = test_results.content_node_id), content_node_id)',
  'study_sessions': "strftime('%d.%m.%Y %H:%M', started_at, 'unixepoch', 'localtime')",
  'session_items': 'label',
  'mock_exams': 'title',
  'mock_exam_sections': 'subject',
  'study_plans': 'title',
  'plan_tasks': 'title',
  'study_notes': 'COALESCE(title, subject)',
  'note_photos': 'path',
  'review_states':
      "COALESCE((SELECT q.subject || ' · ' || q.source_name FROM question_cards q WHERE q.id = review_states.card_id), card_id)",
  'ocr_results': "owner_type || ' · ' || owner_id",
};
