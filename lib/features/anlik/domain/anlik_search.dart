import '../../../core/text/turkish_text.dart';
import 'anlik.dart';
import 'tag_tree.dart';

/// Anlık notlarda arama: kelime, etiket (alt etiketler dahil), kişi, tarih
/// aralığı, ders. Boş alan = o ölçüt yok. Ölçütlerin hepsi birlikte sağlanır.
class AnlikFilter {
  const AnlikFilter({
    this.query = '',
    this.tagId,
    this.personId,
    this.from,
    this.to,
    this.subject,
    this.kind,
  });

  final String query;
  final String? tagId;
  final String? personId;

  /// Gün başı (dahil) ve gün sonu (dahil) olarak okunur.
  final DateTime? from;
  final DateTime? to;
  final String? subject;
  final AnlikKind? kind;

  bool get isEmpty =>
      query.trim().isEmpty && tagId == null && personId == null && from == null && to == null && subject == null && kind == null;
}

/// En yeni başta. Kelimelerin hepsi geçmeli ("ve" mantığı).
List<AnlikNote> filterAnlik(
  Iterable<AnlikNote> notes,
  AnlikFilter f, {
  Iterable<Tag> tags = const [],
}) {
  final words = normalizeTr(f.query).split(' ').where((w) => w.isNotEmpty).toList();
  final tagSet = f.tagId == null ? null : tagWithDescendants(tags, f.tagId!);
  final from = f.from == null ? null : DateTime(f.from!.year, f.from!.month, f.from!.day);
  final to = f.to == null ? null : DateTime(f.to!.year, f.to!.month, f.to!.day + 1);
  final out = [
    for (final n in notes)
      if ((f.kind == null || n.kind == f.kind) &&
          (f.subject == null || n.subject == f.subject) &&
          (tagSet == null || n.tagIds.any(tagSet.contains)) &&
          (f.personId == null || n.personIds.contains(f.personId)) &&
          (from == null || !n.createdAt.isBefore(from)) &&
          (to == null || n.createdAt.isBefore(to)) &&
          words.every(n.searchText.contains))
        n,
  ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

/// Uyku kaydı: bir "yattım" ve ondan sonraki ilk "kalktım" bir gece sayılır.
class SleepNight {
  const SleepNight(this.bed, this.wake);
  final DateTime bed;
  final DateTime? wake; // null: henüz kalkmadı
  Duration? get length => wake?.difference(bed);
}

List<SleepNight> sleepNights(Iterable<AnlikNote> notes) {
  final sleep = [for (final n in notes) if (n.isSleep) n]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final out = <SleepNight>[];
  DateTime? bed;
  for (final n in sleep) {
    if (n.kind == AnlikKind.yattim) {
      if (bed != null) out.add(SleepNight(bed, null)); // kalkmayı unutmuş
      bed = n.createdAt;
    } else if (bed != null) {
      out.add(SleepNight(bed, n.createdAt));
      bed = null;
    }
  }
  if (bed != null) out.add(SleepNight(bed, null));
  return out;
}
