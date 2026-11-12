import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/database_snapshot.dart';
import '../domain/import_models.dart';
import '../domain/import_rules.dart';

class ImportException implements Exception {
  const ImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Telefondaki veritabanı kopyasını bu veritabanına satır satır birleştirir.
///
/// Kural "telefon kazanır": aynı kimlikli satır telefondakiyle değişir, yeni
/// satır eklenir. Bilgisayarda olup kopyada olmayan satır SİLİNMEZ; yalnızca
/// raporlanır ("telefonda silindi") ve kullanıcı elle siler. Uygulama ayarları
/// (app_meta) alınmaz. Tablo ve sütun listesi şemadan okunur: şema değişince
/// bu kod değişmez.
class SnapshotMerger {
  SnapshotMerger(this._db);

  final AppDatabase _db;

  Future<List<TableMerge>> merge(File snapshot) async {
    final version = sqliteUserVersion(await _header(snapshot));
    if (version == null) throw const ImportException('Veritabanı kopyası okunamadı (SQLite dosyası değil).');
    if (version > _db.schemaVersion) {
      throw ImportException('Telefondaki uygulama daha yeni (şema $version, bilgisayar ${_db.schemaVersion}). '
          'Bilgisayar uygulamasını güncelle.');
    }
    // Eski telefon sürümünün kopyası: önce aynı göçlerle bugünkü şemaya yükseltilir.
    if (version < _db.schemaVersion) await _upgrade(snapshot);

    // Masaüstünde oturum başlatılmaz; telefonun "aynı anda tek koşan oturum"
    // kuralı burada gereksizdir ve telefonda silinmiş eski bir oturumla çakışabilir.
    await _db.customStatement('DROP INDEX IF EXISTS ux_single_running_session');
    await _detach(); // yarıda kalmış önceki bir içe aktarmadan kalan bağlantı
    await _db.customStatement('ATTACH DATABASE ? AS tel', [snapshot.path]);
    try {
      final available = {
        for (final r in await _db.customSelect("SELECT name FROM tel.sqlite_master WHERE type = 'table'").get())
          r.read<String>('name'),
      };
      final results = <TableMerge>[];
      await _db.transaction(() async {
        // Tablolar sırayla işlenir; yabancı anahtarlar işlemin sonunda denetlenir.
        await _db.customStatement('PRAGMA defer_foreign_keys = ON');
        for (final table in _db.allTables) {
          final name = table.actualTableName;
          if (skippedTables.contains(name) || !available.contains(name)) continue;
          results.add(await _mergeTable(table));
        }
      });
      // Defter ve analizler gibi akış sorguları yenilensin.
      _db.notifyUpdates({for (final t in _db.allTables) TableUpdate.onTable(t)});
      return results;
    } finally {
      try {
        await _detach();
      } catch (_) {
        // Asıl hatayı gölgelemesin; bir sonraki içe aktarma yeniden dener.
      }
    }
  }

  Future<void> _detach() async {
    final attached = await _db.customSelect('PRAGMA database_list').get();
    if (attached.any((r) => r.read<String>('name') == 'tel')) {
      await _db.customStatement('DETACH DATABASE tel');
    }
  }

  Future<TableMerge> _mergeTable(TableInfo<Table, Object?> table) async {
    final name = table.actualTableName;
    final key = table.$primaryKey.single.$name;
    final t = '"$name"';
    final k = '"$key"';
    final cols = [for (final c in table.$columns) '"${c.$name}"'].join(', ');
    // Telefonda olup bilgisayarda olmayan ya da farklı olan satırlar.
    final changed = 'SELECT $cols FROM tel.$t EXCEPT SELECT $cols FROM main.$t';

    Future<int> count(String sql) async => (await _db.customSelect(sql).getSingle()).read<int>('n');
    final total = await count('SELECT COUNT(*) AS n FROM tel.$t');
    final added = await count('SELECT COUNT(*) AS n FROM tel.$t WHERE $k NOT IN (SELECT $k FROM main.$t)');
    final updated = await count('SELECT COUNT(*) AS n FROM ($changed) WHERE $k IN (SELECT $k FROM main.$t)');
    final missing = [
      for (final r in await _db
          .customSelect('SELECT $k AS id FROM main.$t WHERE $k NOT IN (SELECT $k FROM tel.$t) ORDER BY $k')
          .get())
        r.read<String>('id'),
    ];

    if (added + updated > 0) {
      final set = [
        for (final c in table.$columns)
          if (c.$name != key) '"${c.$name}" = excluded."${c.$name}"',
      ];
      // "WHERE true": SQLite'ta INSERT … SELECT … ON CONFLICT ayrımı için gerekli.
      await _db.customStatement('INSERT INTO main.$t ($cols) SELECT $cols FROM ($changed) WHERE true '
          'ON CONFLICT($k) DO ${set.isEmpty ? 'NOTHING' : 'UPDATE SET ${set.join(', ')}'}');
    }
    return TableMerge(table: name, total: total, added: added, updated: updated, missingIds: missing);
  }

  Future<void> _upgrade(File snapshot) async {
    final old = AppDatabase(NativeDatabase(snapshot));
    try {
      await old.customSelect('SELECT 1').get(); // açılış göçleri burada çalışır
    } finally {
      await old.close();
    }
  }

  static Future<List<int>> _header(File f) async {
    final raf = await f.open();
    try {
      return await raf.read(100);
    } finally {
      await raf.close();
    }
  }
}
