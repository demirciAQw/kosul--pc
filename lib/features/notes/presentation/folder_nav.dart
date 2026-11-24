import '../domain/ink_folder.dart';

/// Klasör seçicide bir satır: klasör ve iç içelik derinliği.
class FolderChoice {
  const FolderChoice(this.folder, this.depth);
  final InkFolderRecord folder;
  final int depth;
}

/// [parentId]'nin doğrudan çocukları (null = kök). Ebeveyni listede olmayan
/// (bozuk/silinmiş) klasörler kökte sayılır; gelen sıra korunur.
List<InkFolderRecord> childFolders(
  List<InkFolderRecord> all,
  String? parentId,
) {
  final ids = {for (final f in all) f.id};
  return [
    for (final f in all)
      if ((f.parentId != null && ids.contains(f.parentId)
              ? f.parentId
              : null) ==
          parentId)
        f,
  ];
}

/// Klasörleri derinlik-öncelikli düz listeye dizer (seçici için); döngü güvenli.
List<FolderChoice> folderChoices(List<InkFolderRecord> all) {
  final out = <FolderChoice>[];
  final seen = <String>{};
  void walk(String? parent, int depth) {
    for (final f in childFolders(all, parent)) {
      if (!seen.add(f.id)) continue;
      out.add(FolderChoice(f, depth));
      walk(f.id, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}

/// Kökten [id]'ye klasör yolu (kendisi dahil); [id] null ya da listede yoksa boş.
List<InkFolderRecord> folderCrumbs(String? id, List<InkFolderRecord> all) {
  final byId = {for (final f in all) f.id: f};
  final out = <InkFolderRecord>[];
  final seen = <String>{};
  var cur = id == null ? null : byId[id];
  while (cur != null && seen.add(cur.id)) {
    out.add(cur);
    cur = cur.parentId == null ? null : byId[cur.parentId];
  }
  return out.reversed.toList();
}

/// "Fizik / Mekanik" gibi yol yazısı.
String folderPathLabel(String? id, List<InkFolderRecord> all) => folderCrumbs(
  id,
  all,
).map((f) => f.name.isEmpty ? 'Adsız klasör' : f.name).join(' / ');
