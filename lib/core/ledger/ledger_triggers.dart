/// Değişiklik defterini besleyen SQLite tetikleyicilerinin üretimi (saf Dart).
///
/// Her senkron tablosunda üç tetikleyici: ekleme, güncelleme (yalnızca satır
/// gerçekten değişince) ve silme. Satır `json_object` ile deftere yazılır;
/// yazanın kimliği ve saat tek satırlık `_baglam` tablosundan gelir. Böylece
/// uygulamanın her yeri ve dışarıdan yazan araçlar kendiliğinden kaydolur.
library;

import '../database/health_tables.dart';

/// Deftere girmeyen tablolar: uygulama ayarları, defterin kendisi ve MEB konu
/// ağacı (`curriculum_nodes`: her cihaz aynı varlıktan kendisi tohumlar; deftere
/// girse her açılışta binlerce gereksiz satır ve sahte çakışma çıkardı).
const ledgerExcludedTables = {
  'app_meta',
  'degisiklikler',
  '_baglam',
  'cakismalar',
  'esitleme_durum',
  'curriculum_nodes',
  // Sağlık verisi hassastır; deftere ve kablosuz eşitlemeye girmez.
  ...healthTables,
};

const ledgerTriggerPrefix = 'trg_ledger_';

String _q(String name) => '"${name.replaceAll('"', '""')}"';

/// Gerçek saat (ms); testlerde `_baglam.saat_ms` ile sabitlenebilir.
const _now = "COALESCE((SELECT saat_ms FROM _baglam WHERE id = 1), "
    "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER))";

/// [blobs]: BLOB sütunları. `json_object` BLOB'u taşıyamaz (hata verir); bu
/// sütunlar `hex()` ile onaltılık metin olarak yazılır, uygulanırken çözülür; NULL BLOB NULL kalır (`hex(NULL)` boş metin verirdi).
String rowJson(String prefix, List<String> columns, {Set<String> blobs = const {}}) =>
    'json_object(${[for (final c in columns) blobs.contains(c) ? "'$c', CASE WHEN $prefix.${_q(c)} IS NULL THEN NULL ELSE hex($prefix.${_q(c)}) END" : "'$c', $prefix.${_q(c)}"].join(', ')})';

/// [table] için tetikleyici adları (ekle, güncelle, sil).
List<String> ledgerTriggerNames(String table) =>
    ['${ledgerTriggerPrefix}${table}_ai', '${ledgerTriggerPrefix}${table}_au', '${ledgerTriggerPrefix}${table}_ad'];

/// CREATE TRIGGER deyimleri (ad sırasıyla). [pk]: tek sütunlu birincil anahtar.
List<String> ledgerTriggerSql(String table, List<String> columns, String pk, {Set<String> blobs = const {}}) {
  final t = _q(table);
  String body(String op, String ref, String? oldJson, String? newJson) => '''
  UPDATE _baglam SET
    hlc_n = CASE WHEN $_now > hlc_ms THEN 0 ELSE hlc_n + 1 END,
    hlc_ms = MAX(hlc_ms, $_now)
  WHERE id = 1;
  INSERT INTO degisiklikler (id, cihaz_id, kaynak, oturum_id, tablo, satir_id, islem, eski, yeni, saat, uzak)
  SELECT lower(hex(randomblob(16))), cihaz_id, kaynak, oturum_id, '$table', CAST($ref.${_q(pk)} AS TEXT), '$op',
         ${oldJson ?? 'NULL'}, ${newJson ?? 'NULL'},
         printf('%013d-%04d-%s', hlc_ms, hlc_n, cihaz_id), 0
  FROM _baglam WHERE id = 1;''';
  const quiet = '(SELECT bastir FROM _baglam WHERE id = 1) = 0';
  final names = ledgerTriggerNames(table);
  return [
    'CREATE TRIGGER IF NOT EXISTS ${names[0]} AFTER INSERT ON $t WHEN $quiet BEGIN\n'
        '${body('ekle', 'NEW', null, rowJson('NEW', columns, blobs: blobs))}\nEND',
    'CREATE TRIGGER IF NOT EXISTS ${names[1]} AFTER UPDATE ON $t WHEN $quiet AND '
        '${rowJson('OLD', columns, blobs: blobs)} IS NOT ${rowJson('NEW', columns, blobs: blobs)} BEGIN\n'
        '${body('degistir', 'NEW', rowJson('OLD', columns, blobs: blobs), rowJson('NEW', columns, blobs: blobs))}\nEND',
    'CREATE TRIGGER IF NOT EXISTS ${names[2]} AFTER DELETE ON $t WHEN $quiet BEGIN\n'
        '${body('sil', 'OLD', rowJson('OLD', columns, blobs: blobs), null)}\nEND',
  ];
}
