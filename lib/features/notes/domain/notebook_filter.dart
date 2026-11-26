/// Defter listesini etikete göre süzme (saf Dart).
library;

import '../../anlik/domain/anlik.dart';
import '../../anlik/domain/tag_tree.dart';
import 'ink_notebook.dart';

/// [tagId] seçiliyse: o etiketi ya da altındaki bir etiketi taşıyan defterler
/// ([tagsOf]: defter → etiket kimlikleri). [tagId] null ise hepsi, sıra korunur.
List<InkNotebookRecord> filterNotebooksByTag(
  List<InkNotebookRecord> notebooks,
  Map<String, Set<String>> tagsOf,
  Iterable<Tag> allTags,
  String? tagId,
) {
  if (tagId == null) return notebooks;
  final wanted = tagWithDescendants(allTags, tagId);
  return [
    for (final n in notebooks)
      if ((tagsOf[n.id] ?? const <String>{}).any(wanted.contains)) n,
  ];
}
