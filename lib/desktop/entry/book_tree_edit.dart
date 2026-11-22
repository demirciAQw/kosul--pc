import '../../features/library/domain/library.dart';

/// Kitap ağacı düzenleme (saf Dart): her işlem yeni bir ağaç döner; düğüm
/// kimlikleri korunur (oturum, soru ve test sonucu bağları kopmasın).

ContentNode editNode(
  ContentNode n, {
  String? title,
  int? questionCount,
  bool clearQuestionCount = false,
  int? pageStart,
  int? pageEnd,
  bool clearPages = false,
  List<ContentNode>? children,
}) =>
    ContentNode(
      id: n.id,
      level: n.level,
      title: title ?? n.title,
      pageStart: clearPages ? null : (pageStart ?? n.pageStart),
      pageEnd: clearPages ? null : (pageEnd ?? n.pageEnd),
      mebNodeId: n.mebNodeId,
      mebMatchScore: n.mebMatchScore,
      questionCount: clearQuestionCount ? null : (questionCount ?? n.questionCount),
      children: children ?? n.children,
    );

/// Yeni düğümü [parentId] altına (null: kökler) ekler; seviye derinlikten gelir.
List<ContentNode> addChildTo(List<ContentNode> roots, String? parentId, ContentNode node) {
  ContentNode withLevel(ContentNode n, int depth) => ContentNode(
        id: n.id,
        level: NodeLevel.fromDepth(depth),
        title: n.title,
        pageStart: n.pageStart,
        pageEnd: n.pageEnd,
        mebNodeId: n.mebNodeId,
        mebMatchScore: n.mebMatchScore,
        questionCount: n.questionCount,
        children: n.children,
      );
  if (parentId == null) return [...roots, withLevel(node, 0)];
  List<ContentNode> walk(List<ContentNode> nodes, int depth) => [
        for (final n in nodes)
          if (n.id == parentId)
            editNode(n, children: [...n.children, withLevel(node, depth + 1)])
          else
            editNode(n, children: walk(n.children, depth + 1)),
      ];
  return walk(roots, 0);
}

List<ContentNode> replaceNode(List<ContentNode> roots, String id, ContentNode Function(ContentNode) fn) => [
      for (final n in roots) n.id == id ? fn(n) : editNode(n, children: replaceNode(n.children, id, fn)),
    ];

List<ContentNode> removeNodeFrom(List<ContentNode> roots, String id) => [
      for (final n in roots)
        if (n.id != id) editNode(n, children: removeNodeFrom(n.children, id)),
    ];

/// Kardeşleri arasında [delta] kadar kaydırır (−1 yukarı, +1 aşağı); sınırda aynı kalır.
List<ContentNode> moveNode(List<ContentNode> roots, String id, int delta) {
  final i = roots.indexWhere((n) => n.id == id);
  if (i >= 0) {
    final j = i + delta;
    if (j < 0 || j >= roots.length) return roots;
    final list = [...roots];
    final n = list.removeAt(i);
    list.insert(j, n);
    return list;
  }
  return [for (final n in roots) editNode(n, children: moveNode(n.children, id, delta))];
}

/// [id] düğümü ve altındakilerin kimlikleri.
Set<String> idsUnder(ContentNode n) => {n.id, for (final d in n.descendants) d.id};
