/// Defter klasörü (v23). Klasörler iç içe olur; defterler klasöre girer.
class InkFolderRecord {
  const InkFolderRecord({
    required this.id,
    required this.parentId,
    required this.name,
    required this.color,
    required this.sortOrder,
    required this.deleted,
    required this.createdAt,
    required this.updatedAt,
    this.notebookCount = 0,
  });

  final String id;

  /// null = kök.
  final String? parentId;
  final String name;
  final int color;
  final int sortOrder;
  final bool deleted;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Doğrudan bu klasördeki silinmemiş defter sayısı (alt klasörler sayılmaz).
  final int notebookCount;
}

/// [folderId]'yi [newParentId] altına koymak döngü yaratır mı? (Kendisi ya da
/// torunlarından birinin altına taşıma.) [parentOf]: klasör -> ebeveyn eşlemesi.
/// Eşitlemeden gelmiş bozuk (döngülü) veri sonsuz döngüye sokmaz.
bool wouldCreateFolderCycle(String folderId, String? newParentId, Map<String, String?> parentOf) {
  final seen = <String>{};
  String? cur = newParentId;
  while (cur != null) {
    if (cur == folderId) return true;
    if (!seen.add(cur)) return false; // zaten döngülü veri: bu taşıma yenisini katmaz
    cur = parentOf[cur];
  }
  return false;
}

/// Kökten [folderId]'ye klasör kimlikleri (kendisi dahil, sonda). Döngü ya da yok
/// olan ebeveyn yolu keser; yaprak klasör yolun sonu olur.
List<String> folderPath(String folderId, Map<String, String?> parentOf) {
  final out = <String>[];
  final seen = <String>{};
  String? cur = folderId;
  while (cur != null && seen.add(cur)) {
    out.add(cur);
    cur = parentOf[cur];
  }
  return out.reversed.toList();
}
