import 'anlik.dart';

/// Etiket ağacı: üst etiket → alt etiketler.

/// [id] ve altındaki tüm etiketlerin kimlikleri (döngüye karşı korumalı).
Set<String> tagWithDescendants(Iterable<Tag> tags, String id) {
  final children = <String?, List<String>>{};
  for (final t in tags) {
    (children[t.parentId] ??= []).add(t.id);
  }
  final out = <String>{};
  final stack = [id];
  while (stack.isNotEmpty) {
    final cur = stack.removeLast();
    if (!out.add(cur)) continue;
    stack.addAll(children[cur] ?? const []);
  }
  return out;
}

/// "his > tiksinti" (kökten yaprağa). Döngü olursa kesilir.
String tagPathLabel(Iterable<Tag> tags, String id) {
  final byId = {for (final t in tags) t.id: t};
  final parts = <String>[];
  final seen = <String>{};
  String? cur = id;
  while (cur != null && seen.add(cur)) {
    final t = byId[cur];
    if (t == null) break;
    parts.insert(0, t.label);
    cur = t.parentId;
  }
  return parts.join(' > ');
}

/// [tagId] etiketinin üstü olarak [candidateParentId] seçilebilir mi?
/// Kendisi ya da altındakiler üst olamaz (döngü).
bool canSetParent(Iterable<Tag> tags, String tagId, String? candidateParentId) =>
    candidateParentId == null || !tagWithDescendants(tags, tagId).contains(candidateParentId);

/// Ağaç sırası: (etiket, derinlik). Kardeşler ada göre.
List<(Tag, int)> tagTreeOrder(Iterable<Tag> tags) {
  final byParent = <String?, List<Tag>>{};
  final ids = {for (final t in tags) t.id};
  for (final t in tags) {
    final p = t.parentId != null && ids.contains(t.parentId) ? t.parentId : null;
    (byParent[p] ??= []).add(t);
  }
  for (final l in byParent.values) {
    l.sort((a, b) => a.name.compareTo(b.name));
  }
  final out = <(Tag, int)>[];
  final seen = <String>{};
  void walk(String? parent, int depth) {
    for (final t in byParent[parent] ?? const <Tag>[]) {
      if (!seen.add(t.id)) continue;
      out.add((t, depth));
      walk(t.id, depth + 1);
    }
  }

  walk(null, 0);
  return out;
}
