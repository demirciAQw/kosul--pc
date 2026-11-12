import 'import_models.dart';

/// İçe aktarılmayan tablo: uygulama ayarları ve bilgisayarın kendi durumu.
const skippedTables = {'app_meta'};

/// "Telefonda silindi" sayılmayan tablolar: MEB konuları her iki tarafta da
/// uygulamanın kendi listesinden kurulur; sürüm farkı silinme demek değildir.
const tombstoneExempt = {'curriculum_nodes', 'app_meta'};

/// Telefonda silinmiş kayıtların güncel listesi: şu an eksik olanlar.
/// Daha önce de eksik olanlar ilk görülme tarihini korur; geri gelenler ve
/// elle silinenler listeden düşer.
List<Tombstone> updateTombstones(
  List<Tombstone> previous,
  Map<String, List<String>> missingNow,
  DateTime now,
) {
  final since = {for (final t in previous) t.key: t.since};
  final out = <Tombstone>[
    for (final e in missingNow.entries)
      if (!tombstoneExempt.contains(e.key))
        for (final id in e.value)
          Tombstone(table: e.key, id: id, since: since['${e.key}/$id'] ?? now),
  ];
  out.sort((a, b) {
    final t = _order(a.table).compareTo(_order(b.table));
    return t != 0 ? t : a.id.compareTo(b.id);
  });
  return out;
}

int _order(String table) {
  final i = tableLabels.keys.toList().indexOf(table);
  return i < 0 ? tableLabels.length : i;
}

/// Yedek, son içe aktarılandan eski mi? (Eski yedek yeni kayıtları "silindi"
/// gösterir ve güncel verinin üstüne eskisini yazar; önce sorulmalı.)
bool isOlderBackup(DateTime? incoming, DateTime? lastImported) =>
    incoming != null && lastImported != null && incoming.isBefore(lastImported);

/// Yedek JSON'undaki dışa aktarma anı.
DateTime? exportedAtOf(Map<String, Object?>? json) {
  final v = json?['exportedAt'];
  return v is String ? DateTime.tryParse(v) : null;
}

/// İzlenen klasörde içe aktarılacak dosya mı? Gizli ve yarım dosyalar
/// (Syncthing ".syncthing.*.tmp", tarayıcı ".part", "~" ile başlayanlar) hariç.
bool isBackupCandidate(String fileName) {
  final n = fileName.toLowerCase();
  return n.endsWith('.zip') && !n.startsWith('.') && !n.startsWith('~');
}

/// Aynı dosyayı iki kez içe aktarmamak için parmak izi.
String fileFingerprint(int size, DateTime modified) => '$size:${modified.millisecondsSinceEpoch}';

/// İzlenen klasördeki bir yedek dosyası.
class BackupFileInfo {
  const BackupFileInfo(this.name, this.size, this.modified);

  final String name;
  final int size;
  final DateTime modified;

  String get fingerprint => fileFingerprint(size, modified);
}

/// İzlenen klasörde içe aktarılacak yedek: işlenmemişlerin en yenisi (en yeni
/// yedek her şeyi içerir). İşlenmemiş daha eskiler "atla" listesine düşer.
({BackupFileInfo? import, List<BackupFileInfo> skip}) pickBackupToImport(
  List<BackupFileInfo> files,
  Map<String, String> processed,
) {
  final fresh = [
    for (final f in files)
      if (isBackupCandidate(f.name) && processed[f.name] != f.fingerprint) f,
  ]..sort((a, b) => b.modified.compareTo(a.modified));
  if (fresh.isEmpty) return (import: null, skip: const <BackupFileInfo>[]);
  return (import: fresh.first, skip: fresh.sublist(1));
}
